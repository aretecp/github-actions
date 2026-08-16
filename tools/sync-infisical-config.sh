#!/usr/bin/env bash
# Mirrors org-level Infisical secrets/vars to per-repo secrets/vars.
# Workaround for GitHub Free orgs: org secrets/vars don't propagate to
# private repos. Until aretecp upgrades to Team or Enterprise, this script
# keeps the per-repo copies in sync.
#
# Usage:
#   ./sync-infisical-config.sh
#
# The script prompts for each secret value (input is hidden). Slugs are
# non-secret and hardcoded.
#
# Compatible with bash 3.2 (macOS default) — no associative arrays.

set -euo pipefail

REPOS=(
  "aretecp/arilearn-phx"
  "aretecp/bd-tracker"
  "aretecp/areteos"
  "aretecp/contact-intelligence"
  "aretecp/arete-terraform-infrastructure"
  "aretecp/website"
  "aretecp/microsoft-entra-terraform-infrastructure"
  "aretecp/performance-review"
)

# Secrets to prompt for. SECRET_VALUES below is filled in parallel order.
SECRETS_TO_PROMPT=(
  INFISICAL_CLIENT_ID
  INFISICAL_CLIENT_SECRET
  INFISICAL_ORG_ID
  INFISICAL_INTERNAL_PROJECT_ID
  INFISICAL_EXTERNAL_PROJECT_ID
  INFISICAL_SHARED_PROJECT_ID
)
SECRET_VALUES=()

# Non-secret variables (parallel arrays — bash 3.2 has no associative arrays).
VAR_NAMES=(
  INFISICAL_INTERNAL_PROJECT_SLUG
  INFISICAL_EXTERNAL_PROJECT_SLUG
  INFISICAL_SHARED_PROJECT_SLUG
)
VAR_VALUES=(
  lumist-labs-internal
  lumist-labs-external
  lumist-labs-shared
)

# --- Prompt for values ---
echo "Enter values for each secret. Input is hidden — press Enter after each."
echo ""
for name in "${SECRETS_TO_PROMPT[@]}"; do
  while true; do
    printf "%-40s " "$name:"
    read -rs value
    echo ""
    if [[ -z "$value" ]]; then
      echo "  empty — try again"
      continue
    fi
    SECRET_VALUES+=("$value")
    break
  done
done

# --- Confirm ---
echo ""
echo "About to write the following to ${#REPOS[@]} repositories:"
for repo in "${REPOS[@]}"; do
  echo "  - $repo"
done
echo ""
echo "Secrets (values hidden):"
for name in "${SECRETS_TO_PROMPT[@]}"; do
  echo "  - $name"
done
echo ""
echo "Variables (visible):"
for i in "${!VAR_NAMES[@]}"; do
  echo "  - ${VAR_NAMES[$i]} = ${VAR_VALUES[$i]}"
done
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# --- Sync ---
for repo in "${REPOS[@]}"; do
  echo ""
  echo "=== $repo ==="

  for i in "${!SECRETS_TO_PROMPT[@]}"; do
    secret="${SECRETS_TO_PROMPT[$i]}"
    value="${SECRET_VALUES[$i]}"
    printf '  secret:   %-40s ' "$secret"
    if gh secret set "$secret" --repo "$repo" --body "$value" >/dev/null 2>&1; then
      echo "OK"
    else
      echo "FAILED"
    fi
  done

  for i in "${!VAR_NAMES[@]}"; do
    var_name="${VAR_NAMES[$i]}"
    var_value="${VAR_VALUES[$i]}"
    printf '  variable: %-40s ' "$var_name = $var_value"
    if gh variable set "$var_name" --repo "$repo" --body "$var_value" >/dev/null 2>&1; then
      echo "OK"
    else
      echo "FAILED"
    fi
  done
done

# --- Verify ---
echo ""
echo "=== Verification ==="
for repo in "${REPOS[@]}"; do
  echo ""
  echo "$repo"
  echo "  Secrets:"
  gh secret list --repo "$repo" 2>/dev/null | awk '/^INFISICAL_/ { print "    " $1 }' || true
  echo "  Variables:"
  gh variable list --repo "$repo" 2>/dev/null | awk '/^INFISICAL_/ { print "    " $1 " = " $2 }' || true
done

echo ""
echo "Done."
