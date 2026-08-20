#!/usr/bin/env bash
# Polls `docker inspect` for a list of containers until all report
# `.State.Health.Status == "healthy"`, or until timeout.
#
# Designed to run on a deploy target (VPS) inside an SSH-action's `script:`
# block. Consumers fetch + pipe at deploy time:
#
#   curl -fsSL "https://raw.githubusercontent.com/aretecp/github-actions/v1/scripts/wait-for-healthy.sh" \
#     | TIMEOUT_SECONDS=150 \
#       COMPOSE_FILE=docker-compose.prod.yml \
#       ENV_FILE=.env \
#       bash -s -- areteos_app areteos_db
#
# Pin to `v1` for moving major, or `<full-sha>` for immutable reproducibility.
#
# Usage:
#   wait-for-healthy.sh <container1> [container2 ...]
#
# Environment variables (all optional):
#   TIMEOUT_SECONDS  — total wait time before giving up (default 150)
#   POLL_INTERVAL    — seconds between polls (default 5)
#   COMPOSE_FILE     — path to docker-compose file. If set, dumps logs from
#                      this compose project on timeout. Default: no log dump.
#   ENV_FILE         — path to .env file passed via --env-file to docker
#                      compose for the log dump. Default: not passed.
#   LOG_TAIL         — number of log lines to dump on timeout (default 100)
#
# Exit codes:
#   0 — all containers reached "healthy" within the timeout
#   1 — timeout reached without all containers healthy (logs dumped if compose-file set)
#   2 — invalid usage

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "ERROR: at least one container name required" >&2
  echo "Usage: $0 <container1> [container2 ...]" >&2
  exit 2
fi

# Re-split on whitespace regardless of how the caller's shell expanded the
# list. vps-deploy-core invokes this as `bash -s -- $HEALTHCHECK_CONTAINERS`
# from an ssh-action script that runs in the TARGET USER'S LOGIN SHELL: bash
# word-splits that unquoted expansion into N args, but zsh passes ONE arg
# containing spaces ("app db" -> docker inspect "app db" -> "not found"
# forever -> guaranteed 150s timeout). Seen live on ssdnode2 (zsh login
# shell), run 32399773948. Container names cannot contain whitespace, so
# re-splitting inside this script (always bash) is safe on both.
read -ra CONTAINERS <<< "$*"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-150}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
ENV_FILE="${ENV_FILE:-}"
LOG_TAIL="${LOG_TAIL:-100}"

MAX_ATTEMPTS=$(( TIMEOUT_SECONDS / POLL_INTERVAL ))
if (( MAX_ATTEMPTS < 1 )); then
  MAX_ATTEMPTS=1
fi

echo "Waiting for ${#CONTAINERS[@]} container(s) to be healthy: ${CONTAINERS[*]}"
echo "Timeout: ${TIMEOUT_SECONDS}s (max ${MAX_ATTEMPTS} attempts × ${POLL_INTERVAL}s)"

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  ALL_HEALTHY=true
  STATUS_LINE=""
  for c in "${CONTAINERS[@]}"; do
    # Separate assignment from fallback so `docker inspect`'s empty-stdout
    # on error doesn't get concatenated with "not found".
    if h=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null); then
      [[ -z "$h" ]] && h="(no health status)"
    else
      h="not found"
    fi
    STATUS_LINE+="${c}=${h} "
    if [[ "$h" != "healthy" ]]; then
      ALL_HEALTHY=false
    fi
  done
  echo "  Attempt $i: $STATUS_LINE"
  if $ALL_HEALTHY; then
    echo "All containers healthy."
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done

echo "ERROR: Containers did not become healthy within ${TIMEOUT_SECONDS}s." >&2

# Best-effort log dump on timeout. Only fires if COMPOSE_FILE is set
# (which is the common case for deploy workflows). Failure to dump
# logs doesn't shadow the original timeout error.
if [[ -n "$COMPOSE_FILE" ]]; then
  echo "Dumping last ${LOG_TAIL} lines of compose logs (-f ${COMPOSE_FILE})..." >&2
  CMD_ARGS=(compose)
  [[ -n "$ENV_FILE" ]] && CMD_ARGS+=(--env-file "$ENV_FILE")
  CMD_ARGS+=(-f "$COMPOSE_FILE" logs --tail="$LOG_TAIL")
  docker "${CMD_ARGS[@]}" >&2 || echo "WARN: log dump failed" >&2
fi

exit 1
