#!/usr/bin/env bash
# Cleans up redundant repo-level vars in `aretecp/arilearn-phx` after the
# prod-side workflows (deploy-prod.yml, rollback-prod.yml, copy-prod-db.yml)
# are migrated to load secrets from Infisical via
# aretecp/github-actions/actions/load-infisical-secrets.
#
# DO NOT RUN until prod is migrated — the targets here are still consumed
# by prod workflows today. Running early breaks prod deploys.
#
# Notes specific to arilearn-phx vs areteos:
#   - No env-level secrets to clean (development + production env secret
#     stores are empty)
#   - No app secrets ever lived at repo level here (POSTGRES_PASSWORD etc.
#     were always sourced from Infisical or env)
#   - ANTHROPIC_API_KEY is still used by claude-issues.yml +
#     pr-to-main-hooks.yml — kept
#
# Compatible with bash 3.2 (macOS default).

set -euo pipefail

REPO=aretecp/arilearn-phx

# Repo-level variables — no longer referenced after prod migration.
# Includes the already-orphaned ones (OTEL_*, PHX_HOST_PROD,
# MCP_RESOURCE_URL_PROD) plus the dev-side ones orphaned by PR #93
# (PHX_HOST_DEV, MCP_RESOURCE_URL_DEV) plus the prod-side ones that go
# orphaned only after prod workflows migrate.
VARS_TO_DELETE=(
  # Already orphaned (safe to delete anytime, even pre-prod-migration)
  OTEL_EXPORTER_OTLP_ENDPOINT
  OTEL_SAMPLE_RATE
  PHX_HOST_PROD
  MCP_RESOURCE_URL_PROD
  # Orphaned after the dev-deploy simplification PR
  PHX_HOST_DEV
  MCP_RESOURCE_URL_DEV
  # Orphaned only after prod workflows migrate
  POSTGRES_USER
  POSTGRES_DB_DEV
  POSTGRES_DB_PROD
  POOL_SIZE
  PORT
  PHX_HOST
  MCP_RESOURCE_URL
)

# --- Confirm ---
cat <<EOF
About to delete from $REPO:
  - ${#VARS_TO_DELETE[@]} repo-level variables

No repo-level or environment-level secrets to delete (this app already
keeps its app secrets in Infisical, not GH).

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

# --- Verify remaining state ---
echo ""
echo "=== Remaining repo-level variables ==="
gh variable list --repo "$REPO" 2>/dev/null

echo ""
echo "=== Remaining repo-level secrets (no changes; for reference) ==="
gh secret list --repo "$REPO" 2>/dev/null

echo ""
echo "Done."
