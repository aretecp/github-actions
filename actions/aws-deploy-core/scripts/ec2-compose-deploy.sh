#!/usr/bin/env bash
# Runs on the target EC2 host via SSM. Static file, checked into the repo —
# not generated per-invocation. Every value it needs arrives as a plain
# environment variable, exported ahead of this script by the calling action.
#
# Expects: REPO_DIR, IMAGE, COMPOSE_FILE, COMPOSE_PROFILES_LIST, AWS_REGION,
# ENV_PARAMETER_NAME, ENV_FILE_NAME, HEALTHCHECK_URL, and COMPOSE_B64_0,
# COMPOSE_B64_1, ... — one per file in COMPOSE_FILE, in the same order. The
# index is positional, set by the caller iterating `for f in $COMPOSE_FILE`
# the same way this script does — nothing about the filename itself needs to
# match between the two sides.
set -euo pipefail

mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

i=0
for f in $COMPOSE_FILE; do
  var_name="COMPOSE_B64_$i"
  printf '%s' "${!var_name}" | base64 -d > "$REPO_DIR/$f"
  i=$((i + 1))
done

# ECR auth via the instance's own role — no credential is ever placed on
# this host by hand or by us.
REGISTRY=$(printf '%s' "$IMAGE" | cut -d/ -f1)
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# Fetched here rather than passed in: SendCommand parameters are kept on the
# command record and copied into CloudWatch.
umask 077
aws ssm get-parameter --name "$ENV_PARAMETER_NAME" --with-decryption \
  --query Parameter.Value --output text > "$REPO_DIR/$ENV_FILE_NAME"

# IMAGE only exists as a shell var for this invocation -- a later, separate
# `docker compose` call on this host (a smoke check, a manual restart) has
# no idea what to interpolate otherwise. Persisting it here, not just
# exporting it below, is what makes those later calls work at all. Only
# takes effect when ENV_FILE_NAME is Compose's own auto-loaded `.env`.
echo "IMAGE=$IMAGE" >> "$REPO_DIR/$ENV_FILE_NAME"

# One -f per file and one --profile per profile. Built as an array so a
# multi-file override stack works without the caller quoting anything.
compose_args=()
for f in $COMPOSE_FILE; do compose_args+=(-f "$f"); done
for p in $COMPOSE_PROFILES_LIST; do compose_args+=(--profile "$p"); done

IMAGE="$IMAGE" docker compose "${compose_args[@]}" pull
IMAGE="$IMAGE" docker compose "${compose_args[@]}" up -d --remove-orphans

if [ -n "$HEALTHCHECK_URL" ]; then
  for i in $(seq 1 30); do
    if curl -fsS "$HEALTHCHECK_URL" >/dev/null 2>&1; then
      echo "healthy after $i attempt(s)"
      exit 0
    fi
    sleep 10
  done
  echo "FATAL: $HEALTHCHECK_URL never returned 2xx" >&2
  docker compose "${compose_args[@]}" ps
  exit 1
fi
