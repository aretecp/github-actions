#!/usr/bin/env bash
# Cleans up redundant repo/env-level secrets and vars in `aretecp/areteos`
# AFTER deploy-prod.yml + rollback-prod.yml + copy-prod-db.yml are migrated
# to load app secrets from Infisical via aretecp/github-actions/actions/load-infisical-secrets.
#
# DO NOT RUN until prod is migrated — the targets here are still consumed
# by prod workflows today. Running early will break prod deploys.
#
# Verify nothing references each target before running:
#   for n in POSTGRES_USER POOL_SIZE OTEL_EXPORTER_OTLP_ENDPOINT ...; do
#     grep -l "secrets.$n\|vars.$n" ../areteos/.github/workflows/*.yml
#   done
# (No matches = safe to delete.)
#
# Compatible with bash 3.2 (macOS default).

set -euo pipefail

REPO=aretecp/areteos

# Repo-level variables — no longer referenced after prod migration
VARS_TO_DELETE=(
  POSTGRES_USER
  POSTGRES_DB_PROD
  POSTGRES_DB_DEV
  POOL_SIZE
  OTEL_EXPORTER_OTLP_ENDPOINT
  OTEL_SAMPLE_RATE
  PHX_HOST
  PHX_HOST_DEV
)

# Repo-level secrets — used by prod workflows today, removable post-migration
REPO_SECRETS_TO_DELETE=(
  MICROSOFT_CLIENT_ID
  MICROSOFT_CLIENT_SECRET
  MICROSOFT_TENANT_ID
  TOKEN_SIGNING_SECRET
)

# Environment-level secrets — each env (development, production) has its own copy.
# These mirror what's now sourced from Infisical.
ENV_SECRETS_TO_DELETE=(
  ANTHROPIC_API_KEY
  ARETEOS_VAULT_KEY
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  LOGFIRE_WRITE_TOKEN
  OPENAI_API_KEY
  PAT_HMAC_KEY
  POSTGRES_PASSWORD
  SECRET_KEY_BASE
  TOKEN_SIGNING_SECRET
)

ENVIRONMENTS=(development production)

# --- Confirm ---
cat <<EOF
About to delete from $REPO:
  - ${#VARS_TO_DELETE[@]} repo-level variables
  - ${#REPO_SECRETS_TO_DELETE[@]} repo-level secrets
  - ${#ENV_SECRETS_TO_DELETE[@]} secrets in each of [${ENVIRONMENTS[*]}] environments
Total: $(( ${#VARS_TO_DELETE[@]} + ${#REPO_SECRETS_TO_DELETE[@]} + ${#ENVIRONMENTS[@]} * ${#ENV_SECRETS_TO_DELETE[@]} )) deletions

EOF
read -rp "Confirm prod workflows are already migrated to Infisical [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# --- Variables ---
echo ""
echo "=== Variables ==="
for v in "${VARS_TO_DELETE[@]}"; do
  printf '  %-40s ' "$v"
  if gh variable delete "$v" --repo "$REPO" >/dev/null 2>&1; then
    echo "deleted"
  else
    echo "(not present or failed)"
  fi
done

# --- Repo-level secrets ---
echo ""
echo "=== Repo-level secrets ==="
for s in "${REPO_SECRETS_TO_DELETE[@]}"; do
  printf '  %-40s ' "$s"
  if gh secret delete "$s" --repo "$REPO" >/dev/null 2>&1; then
    echo "deleted"
  else
    echo "(not present or failed)"
  fi
done

# --- Environment-level secrets ---
echo ""
echo "=== Environment-level secrets ==="
for env in "${ENVIRONMENTS[@]}"; do
  echo "  [$env]"
  for s in "${ENV_SECRETS_TO_DELETE[@]}"; do
    printf '    %-38s ' "$s"
    if gh secret delete "$s" --repo "$REPO" --env "$env" >/dev/null 2>&1; then
      echo "deleted"
    else
      echo "(not present or failed)"
    fi
  done
done

# --- Verify remaining state ---
echo ""
echo "=== Remaining repo-level secrets ==="
gh secret list --repo "$REPO" 2>/dev/null

echo ""
echo "=== Remaining repo-level variables ==="
gh variable list --repo "$REPO" 2>/dev/null

for env in "${ENVIRONMENTS[@]}"; do
  echo ""
  echo "=== Remaining $env environment secrets ==="
  gh secret list --repo "$REPO" --env "$env" 2>/dev/null
done

echo ""
echo "Done."
