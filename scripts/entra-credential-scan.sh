#!/usr/bin/env bash
# Enumerate every app registration in the Entra tenant and report each
# credential's expiry. Emits a JSON array on stdout, sorted soonest-first.
#
# Reads Graph directly rather than Infisical on purpose: Graph is the source of
# truth and sees credentials Terraform never created. A hand-made portal secret
# is exactly what expired unnoticed and broke arilearn prod on 2026-07-29 — an
# Infisical-based check is blind to those.
#
# Read-only. The monitor identity holds Application.Read.All and nothing more;
# it cannot mint, modify, or delete a credential.
#
# Usage:  GRAPH_TOKEN=<bearer> ./entra-credential-scan.sh > scan.json
#
# Output record shape:
#   { app, app_id, kind, name, key_id, expires, days_left, terraform_managed }
#
# `kind` is "secret" (passwordCredentials) or "certificate" (keyCredentials).
# Certificates expire too, and the same propagation problem applies to them.

set -euo pipefail

: "${GRAPH_TOKEN:?GRAPH_TOKEN is required}"

RAW="$(mktemp)"
BODY="$(mktemp)"
trap 'rm -f "$RAW" "$BODY"' EXIT

graph_get() {
  local url="$1" code
  code=$(curl -sS -o "$BODY" -w '%{http_code}' \
    -H "Authorization: Bearer ${GRAPH_TOKEN}" \
    -H 'Accept: application/json' \
    "$url")

  case "$code" in
    200) cat "$BODY" ;;
    401)
      echo "Graph returned 401 — the token was rejected." >&2
      echo "Check the federated credential subject matches this workflow's ref." >&2
      exit 1
      ;;
    403)
      echo "Graph returned 403 Authorization_RequestDenied." >&2
      echo "" >&2
      echo "Almost certainly missing tenant admin consent for Application.Read.All." >&2
      echo "The token exchange succeeds without consent — only the Graph call fails," >&2
      echo "so this is the expected symptom of an unconsented app." >&2
      echo "" >&2
      echo "Fix:  az ad app permission admin-consent --id <monitor client id>" >&2
      echo "See apps/entra_secret_monitor/POST-APPLY.md in" >&2
      echo "aretecp/microsoft-entra-terraform-infrastructure." >&2
      exit 1
      ;;
    *)
      echo "Graph returned HTTP ${code}:" >&2
      head -c 2000 "$BODY" >&2
      exit 1
      ;;
  esac
}

# $top=999 keeps this to a single page for any plausible tenant size, but follow
# @odata.nextLink anyway — a silent truncation here reads as "nothing expiring".
# shellcheck disable=SC2016  # $select/$top are OData query params — they must NOT expand
URL='https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,passwordCredentials,keyCredentials&$top=999'
: > "$RAW"
PAGES=0

while [ -n "$URL" ]; do
  PAGE="$(graph_get "$URL")"
  printf '%s' "$PAGE" | jq -c '.value[]' >> "$RAW"
  URL="$(printf '%s' "$PAGE" | jq -r '."@odata.nextLink" // ""')"
  PAGES=$((PAGES + 1))
done

echo "Scanned ${PAGES} page(s), $(wc -l < "$RAW" | tr -d ' ') app registration(s)." >&2

# Graph returns fractional seconds on endDateTime ("...:55.8238406Z"), which
# fromdateiso8601 cannot parse — strip the fraction before converting.
jq -s --argjson now "$(date -u +%s)" '
  [ .[] as $app
    | ( (($app.passwordCredentials // []) | map(. + {kind: "secret"}))
      + (($app.keyCredentials      // []) | map(. + {kind: "certificate"})) )[]
    | select(.endDateTime != null)
    | {
        app:               ($app.displayName // "(unnamed app)"),
        app_id:            $app.appId,
        kind:              .kind,
        name:              (.displayName // "(unnamed credential)"),
        key_id:            .keyId,
        expires:           .endDateTime,
        days_left:         ((((.endDateTime | sub("\\.[0-9]+"; "")) | fromdateiso8601) - $now) / 86400 | floor),
        terraform_managed: ((.displayName // "") | startswith("terraform-managed"))
      }
  ] | sort_by(.days_left)
' "$RAW"
