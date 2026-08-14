#!/usr/bin/env bash
# Reclaims Docker disk on a deploy target, then reports usage against a
# threshold so a caller can alert on it.
#
# Replaces /home/sglyon/bin/docker-builder-prune.sh, which pruned build cache
# only and reported nothing. On 2026-08-14 the Docker data-root volume reached
# 100%, every Postgres on the box refused to start ("could not write lock file
# postmaster.pid: No space left on device"), and Infisical crashlooped, which
# broke deploys that fetch secrets. That script had run at 04:00 the same day,
# reclaimed 7.84GB, and logged 100% immediately afterward to a file nobody read.
#
# Install with install-docker-prune.sh. Runs unattended, so it is deliberately
# conservative: see "What this does NOT prune" before adding a step.
#
# Usage:
#   docker-prune.sh
#
# Environment variables (all optional):
#   DISK_PATH      — filesystem to report on (default /mnt/HC_Volume_103786129,
#                    the Docker data-root per /etc/docker/daemon.json)
#   WARN_PCT       — usage percent that triggers a non-zero exit (default 85)
#   MIN_FREE_GB    — absolute free GiB below which we exit non-zero (default 20)
#   BUILDER_UNTIL  — age filter for build cache (default 24h)
#   IMAGE_PRUNE    — "false" to skip the dangling-image prune (default true)
#   LOG_FILE       — tee output here and rotate it (default: stdout only)
#   LOG_MAX_BYTES  — rotate LOG_FILE past this size (default 1048576)
#   STATE_DIR      — where to write the machine-readable status file
#                    (default $HOME/.local/state/docker-prune)
#   DRY_RUN        — "true" prints the prune commands without running them
#
# Exit codes:
#   0 — pruned, usage under both thresholds
#   1 — usage at/over WARN_PCT, or free space under MIN_FREE_GB. Actionable.
#   2 — invalid configuration
#   3 — docker daemon not reachable
#   4 — a prune step failed but thresholds are still fine
#
# A threshold breach outranks a prune failure: exit 1 wins over exit 4, because
# "the disk is nearly full" is the fact that needs a human, not "one prune
# command errored".

# NOT `set -e`, on purpose. The old script's missing -e was flagged as a defect,
# but a janitor that aborts on the first failed prune also skips the disk report
# and the threshold check — losing exactly the signal this exists to produce.
# Step failures are tracked explicitly in FAILED_STEPS and surface as exit 4.
set -uo pipefail

DISK_PATH="${DISK_PATH:-/mnt/HC_Volume_103786129}"
WARN_PCT="${WARN_PCT:-85}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
BUILDER_UNTIL="${BUILDER_UNTIL:-24h}"
IMAGE_PRUNE="${IMAGE_PRUNE:-true}"
LOG_FILE="${LOG_FILE:-}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/docker-prune}"
DRY_RUN="${DRY_RUN:-false}"

FAILED_STEPS=""

# ── Logging ────────────────────────────────────────────────────────────────
# Rotation lives here rather than in /etc/logrotate.d because installing there
# needs root, and this script is installed by a non-root user on the VPS.
# One generation is enough: the status file is the durable record, the log is
# for reading after something went wrong.
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")" || {
    echo "ERROR: cannot create log directory for $LOG_FILE" >&2
    exit 2
  }
  if [[ -f "$LOG_FILE" ]]; then
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
      mv -f "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
  # Process substitution, so tee's exit status never becomes the script's.
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S%z') docker-prune start ====="

if ! [[ "$WARN_PCT" =~ ^[0-9]+$ ]] || (( WARN_PCT < 1 || WARN_PCT > 100 )); then
  echo "ERROR: WARN_PCT must be 1-100, got '$WARN_PCT'" >&2
  exit 2
fi
if ! [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]]; then
  echo "ERROR: MIN_FREE_GB must be an integer, got '$MIN_FREE_GB'" >&2
  exit 2
fi
if ! df --output=pcent "$DISK_PATH" >/dev/null 2>&1; then
  echo "ERROR: cannot stat DISK_PATH '$DISK_PATH'" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker daemon not reachable (in the docker group?)" >&2
  exit 3
fi

# ── Disk helpers ───────────────────────────────────────────────────────────
# `df --output` is GNU coreutils; the target is Ubuntu 24.04, which has it.
# tr -dc strips the trailing % and leading whitespace in one pass.
disk_pcent() { df --output=pcent "$DISK_PATH" | tail -1 | tr -dc '0-9'; }
disk_free_bytes() { df --output=avail -B1 "$DISK_PATH" | tail -1 | tr -dc '0-9'; }
gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

PCT_BEFORE="$(disk_pcent)"
FREE_BEFORE="$(disk_free_bytes)"
echo "before: ${PCT_BEFORE}% used, $(gib "$FREE_BEFORE") GiB free on $DISK_PATH"

run_step() {
  local label="$1"; shift
  echo "--- $label"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY_RUN: $*"
    return 0
  fi
  if ! "$@"; then
    echo "WARN: $label failed" >&2
    FAILED_STEPS+="${FAILED_STEPS:+,}$label"
  fi
}

# ── Prune, images before cache ─────────────────────────────────────────────
# Order matters. Removing a dangling image releases its layers, which lets the
# subsequent build-cache prune drop the cache records that referenced them.
# Cache-first leaves those records pinned until the next run.
#
# `image prune` without -a removes only untagged images. That is precisely the
# rebuild garbage: each areteos-py deploy retags <project>-<service>:latest and
# strands the previous 2.31GB image as <none> with no container. Two such
# images were sitting on the box, three hours old, when this was written; 322
# of them were what filled the volume.
if [[ "$IMAGE_PRUNE" == "true" ]]; then
  run_step "dangling images" docker image prune -f
else
  echo "--- dangling images (skipped, IMAGE_PRUNE=$IMAGE_PRUNE)"
fi

# 24h, down from the old 72h. At several 2.31GB builds per day, three days of
# retained cache on its own exceeds the headroom this volume has.
run_step "build cache older than $BUILDER_UNTIL" \
  docker builder prune -f --filter "until=$BUILDER_UNTIL"

# ── What this does NOT prune, and why ──────────────────────────────────────
# Do not add any of these without re-reading this block. Each was considered
# and rejected against the actual contents of this box.
#
# docker volume prune — offers ~6.9GB across 25 unused volumes, which include
#   areteos_test_pg and the arilearn blue/green standby's data. Real data for a
#   rounding error of space.
#
# docker image prune -a — removes every image not used by a *running*
#   container. That is ~12-15GB of images belonging to stopped-but-live apps:
#   arilearn-phx-migrate, 8x contact-intelligence-*, 3x lindesvard/openpanel-*,
#   litellm, clickhouse, neo4j, prometheus, 2x watterson-*-dev. Deleting them
#   turns a parked app into a rebuild-from-scratch.
#
# docker system prune -af — both of the above at once.
#
# docker container prune — the plan called for --filter until=168h. On this box
#   that would delete arilearn-phx-app_green-1, the blue/green standby slot,
#   which had been exited 6 days when this was written and was therefore one
#   day from the cutoff. Also areteos_test_pg. Total reclaim: 5.4MB. There is
#   no --filter name!=..., so the only safe form is an explicit allowlist of
#   one-shot job containers, and 5.4MB does not justify one.

# ── Report ─────────────────────────────────────────────────────────────────
PCT_AFTER="$(disk_pcent)"
FREE_AFTER="$(disk_free_bytes)"
FREE_GB_AFTER="$(gib "$FREE_AFTER")"
RECLAIMED_GB="$(gib "$(( FREE_AFTER - FREE_BEFORE ))")"

echo "after: ${PCT_AFTER}% used, ${FREE_GB_AFTER} GiB free (reclaimed ${RECLAIMED_GB} GiB)"

BREACH=""
(( PCT_AFTER >= WARN_PCT )) && BREACH="usage ${PCT_AFTER}% >= ${WARN_PCT}%"
# Absolute free space matters independently of percent: 8% of a 197GB volume is
# 15GB, which is under two areteos-py image builds. Percent alone under-reads
# the danger on a volume this size.
if awk -v f="$FREE_GB_AFTER" -v m="$MIN_FREE_GB" 'BEGIN { exit !(f < m) }'; then
  BREACH="${BREACH:+$BREACH; }free ${FREE_GB_AFTER} GiB < ${MIN_FREE_GB} GiB"
fi

if [[ -n "$BREACH" ]]; then
  EXIT_CODE=1
elif [[ -n "$FAILED_STEPS" ]]; then
  EXIT_CODE=4
else
  EXIT_CODE=0
fi

# Single machine-readable line, greppable out of the log by a monitor that
# only has shell access.
echo "RESULT usage_pct=${PCT_AFTER} free_gb=${FREE_GB_AFTER} reclaimed_gb=${RECLAIMED_GB} exit=${EXIT_CODE} failed_steps=${FAILED_STEPS:-none}"

# Status file: one stable path for an external monitor to read, so it never has
# to parse the log or tail the journal. Written atomically — a monitor polling
# every 30 minutes must never catch a half-written file.
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  STATUS_FILE="$STATE_DIR/status.json"
  TMP_FILE="$STATUS_FILE.tmp.$$"
  printf '{"ts":"%s","host":"%s","disk_path":"%s","usage_pct":%s,"free_gb":%s,"reclaimed_gb":%s,"warn_pct":%s,"min_free_gb":%s,"exit_code":%s,"failed_steps":"%s","breach":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)" "$DISK_PATH" \
    "$PCT_AFTER" "$FREE_GB_AFTER" "$RECLAIMED_GB" \
    "$WARN_PCT" "$MIN_FREE_GB" "$EXIT_CODE" \
    "${FAILED_STEPS:-}" "${BREACH:-}" > "$TMP_FILE" \
    && mv -f "$TMP_FILE" "$STATUS_FILE" \
    || echo "WARN: could not write status file to $STATUS_FILE" >&2
else
  echo "WARN: could not create STATE_DIR '$STATE_DIR'; no status file written" >&2
fi

if [[ -n "$BREACH" ]]; then
  echo "ERROR: disk threshold breached — $BREACH" >&2
fi

echo "===== done (exit $EXIT_CODE) ====="
exit "$EXIT_CODE"
