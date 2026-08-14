#!/usr/bin/env bash
# Installs docker-prune.sh on a deploy target and schedules it.
#
# Runs ON the VPS, as the user that owns the Docker containers (sglyon on the
# Areté box). Idempotent — re-run it to update the script or change the schedule.
#
# Two schedulers, picked by what the box allows:
#
#   systemd timer — chosen when passwordless sudo is available. Preferred:
#     OnFailure= gives the threshold exit an alert path, journalctl replaces the
#     log file, and Persistent=true catches runs missed across a reboot.
#   user crontab  — the fallback. Needs no privilege at all. The Areté VPS is
#     here: sglyon is in the sudo group but sudo prompts for a password, and an
#     unattended installer must not prompt for or store one.
#
# When it falls back, it prints the single sudo command to switch to systemd.
#
# Usage, from a checkout:
#   scripts/install-docker-prune.sh
#
# Usage, standalone (fetches docker-prune.sh from SOURCE_REF):
#   curl -fsSL "https://raw.githubusercontent.com/aretecp/github-actions/v2/scripts/install-docker-prune.sh" | bash
#
# Environment variables (all optional):
#   INSTALL_DIR   — where docker-prune.sh lands (default $HOME/bin)
#   SCHEDULE_HOURS— hours between runs (default 6)
#   SOURCE_REF    — git ref to fetch docker-prune.sh from when there is no
#                   sibling copy (default v2, this suite's moving major)
#   LOG_FILE      — log path passed to the script (default $HOME/log/docker-prune.log)
#   FORCE_CRON    — "true" to skip the systemd path even where sudo works
#   DRY_RUN       — "true" to print what would change and exit
#
# Exit codes:
#   0 — installed and scheduled
#   1 — install failed
#   2 — invalid configuration

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
SCHEDULE_HOURS="${SCHEDULE_HOURS:-6}"
SOURCE_REF="${SOURCE_REF:-v2}"
LOG_FILE="${LOG_FILE:-$HOME/log/docker-prune.log}"
FORCE_CRON="${FORCE_CRON:-false}"
DRY_RUN="${DRY_RUN:-false}"

TARGET="$INSTALL_DIR/docker-prune.sh"
# The script this one replaces. Its crontab line is removed; the file itself is
# left on disk deliberately — deleting another operator's script is not this
# installer's call.
LEGACY_SCRIPT="docker-builder-prune.sh"

if ! [[ "$SCHEDULE_HOURS" =~ ^[0-9]+$ ]] || (( SCHEDULE_HOURS < 1 || SCHEDULE_HOURS > 24 )); then
  echo "ERROR: SCHEDULE_HOURS must be 1-24, got '$SCHEDULE_HOURS'" >&2
  exit 2
fi

say() { echo "[install-docker-prune] $*"; }

# ── 1. Place the script ────────────────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
SIBLING="${SELF_DIR:+$SELF_DIR/docker-prune.sh}"

if [[ "$DRY_RUN" == "true" ]]; then
  say "DRY_RUN — would install to $TARGET, schedule every ${SCHEDULE_HOURS}h"
  exit 0
fi

mkdir -p "$INSTALL_DIR" "$(dirname "$LOG_FILE")"

if [[ -n "$SIBLING" && -f "$SIBLING" ]]; then
  say "installing from local checkout: $SIBLING"
  install -m 0755 "$SIBLING" "$TARGET"
else
  # Piped into bash, so there is no sibling file to copy. Fetch to a temp path
  # and only move it into place once the download succeeded, so a network
  # failure can't leave a truncated janitor installed.
  say "no local copy found; fetching docker-prune.sh at ref '$SOURCE_REF'"
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  curl -fsSL \
    "https://raw.githubusercontent.com/aretecp/github-actions/${SOURCE_REF}/scripts/docker-prune.sh" \
    -o "$TMP"
  install -m 0755 "$TMP" "$TARGET"
fi

say "installed $TARGET"

# Smoke-test before scheduling, so a broken install surfaces now rather than at
# midnight. Exit 1 and 4 are threshold/step signals, not install problems; only
# 2 (bad config) and 3 (no docker) mean this box can't run it.
set +e
DRY_RUN=true LOG_FILE="" "$TARGET" >/dev/null 2>&1
smoke=$?
set -e
if (( smoke == 2 || smoke == 3 )); then
  say "ERROR: '$TARGET' exited $smoke under DRY_RUN (2=bad config, 3=no docker)"
  say "not scheduling a script that cannot run. Fix that first."
  exit 1
fi

# ── 2. Schedule ────────────────────────────────────────────────────────────
have_passwordless_sudo() { sudo -n true >/dev/null 2>&1; }

# Drop crontab lines for this script and the one it replaces, leaving anything
# else alone. Called by both schedulers: the systemd path must clear the cron
# entry too, or an upgrade from cron leaves two janitors running.
remove_cron_entries() {
  local current filtered
  current="$(crontab -l 2>/dev/null || true)"
  [[ -z "$current" ]] && return 0

  if ! printf '%s\n' "$current" | grep -qE "$LEGACY_SCRIPT|docker-prune\.sh"; then
    return 0
  fi

  filtered="$(printf '%s\n' "$current" \
    | grep -vF "$LEGACY_SCRIPT" \
    | grep -vF "docker-prune.sh" \
    | sed '/^$/d' || true)"

  if [[ -z "$filtered" ]]; then
    crontab -r 2>/dev/null || true
  else
    printf '%s\n' "$filtered" | crontab -
  fi

  if printf '%s\n' "$current" | grep -qF "$LEGACY_SCRIPT"; then
    say "removed the legacy '$LEGACY_SCRIPT' crontab line"
    say "its script file was left in place; delete it yourself once happy"
  fi
}

install_systemd() {
  say "passwordless sudo available — installing systemd timer"

  # OnFailure fires on the threshold exit (1) and on a failed prune step (4),
  # which is the alert path cron cannot offer.
  sudo tee /etc/systemd/system/docker-prune.service >/dev/null <<UNIT
[Unit]
Description=Reclaim Docker disk and report usage against a threshold
Documentation=https://github.com/aretecp/github-actions/blob/main/scripts/README.md
After=docker.service
Wants=docker.service
OnFailure=docker-prune-failed.service

[Service]
Type=oneshot
User=$USER
# No LOG_FILE on purpose: journald captures stdout, which is the whole reason
# to prefer this path over cron. Read it with journalctl -u docker-prune.
ExecStart=$TARGET
UNIT

  sudo tee /etc/systemd/system/docker-prune-failed.service >/dev/null <<UNIT
[Unit]
Description=Loud journal marker when docker-prune reports a breach

[Service]
Type=oneshot
ExecStart=/usr/bin/logger -t docker-prune -p daemon.err "docker-prune FAILED or breached threshold — see: journalctl -u docker-prune -n 50"
UNIT

  # RandomizedDelaySec keeps the prune off the exact hour, where it would
  # otherwise collide with deploys that land on cron-round times.
  sudo tee /etc/systemd/system/docker-prune.timer >/dev/null <<UNIT
[Unit]
Description=Run docker-prune every ${SCHEDULE_HOURS}h

[Timer]
OnCalendar=*-*-* 0/${SCHEDULE_HOURS}:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now docker-prune.timer
  remove_cron_entries
  say "systemd timer enabled — check: systemctl list-timers docker-prune.timer"
}

install_cron() {
  say "installing user crontab entry (every ${SCHEDULE_HOURS}h)"

  local entry="0 */${SCHEDULE_HOURS} * * * LOG_FILE=$LOG_FILE $TARGET"

  remove_cron_entries

  local kept
  kept="$(crontab -l 2>/dev/null | sed '/^$/d' || true)"
  printf '%s\n' "${kept:+$kept}" "$entry" | sed '/^$/d' | crontab -

  say "crontab now:"
  crontab -l | sed 's/^/    /'
}

if [[ "$FORCE_CRON" != "true" ]] && have_passwordless_sudo; then
  install_systemd
else
  if [[ "$FORCE_CRON" == "true" ]]; then
    say "FORCE_CRON=true — skipping systemd"
  else
    say "no passwordless sudo — falling back to cron"
  fi
  install_cron

  if [[ "$FORCE_CRON" != "true" ]]; then
    cat <<'MSG'

To switch to a systemd timer instead — alert path on failure, journal instead of
a log file, survives missed runs — authenticate sudo first, then re-run this
installer as your normal user. `sudo -v` caches the credential, which is what
the systemd path checks for:

    sudo -v && scripts/install-docker-prune.sh

That leaves the crontab line in place; the installer removes it on the systemd
path, so run it in that order rather than the reverse.

MSG
  fi
fi

# ── 3. Show current state ──────────────────────────────────────────────────
say "running once now to seed the status file"
if LOG_FILE="$LOG_FILE" "$TARGET"; then
  say "first run clean"
else
  code=$?
  say "first run exited $code — that is the threshold signal, not an install failure"
fi

say "status file: \${STATE_DIR:-\$HOME/.local/state/docker-prune}/status.json"
say "done"
