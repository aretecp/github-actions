# `teams-notify`

Post a MessageCard to a Teams incoming webhook.

Built for infra workflows that need to reach the channel the team already watches —
credential rotation notices, deploy approval gates, dead-man's-switch heartbeats.
Reaching an existing channel is the whole point; a GitHub issue nobody has open is
not a notification.

## Usage

```yaml
- name: Load Teams webhook
  uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    method: oidc
    identity-id: ${{ vars.INFISICAL_OIDC_IDENTITY_ID }}
    project-slug: ${{ vars.INFISICAL_SHARED_PROJECT_SLUG }}
    environment: prod
    path: /teams/pr-notify

- name: Notify Teams
  uses: aretecp/github-actions/actions/teams-notify@v1
  env:
    TEAMS_WEBHOOK_URL: ${{ env.TEAMS_PR_NOTIFY_WEBHOOK_URL }}
  with:
    title: Rotating arilearn client secret
    status: warning
    text: |
      Secret expires in **12 days**. Rotation starting now.

      Cancel the workflow run if this is a bad time — nothing has changed yet.
    facts: '[{"name":"App","value":"arilearn"},{"name":"Expires","value":"2026-08-11"}]'
    button-url: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
    button-label: Watch run
```

## Inputs

| Input | Required | Default | Description |
|---|:---:|---|---|
| `title` | yes | — | Card title. Shown in the Teams notification preview, so lead with what matters. |
| `text` | yes | — | Body text. Teams MessageCards render markdown. |
| `status` | no | `info` | `info` / `success` / `warning` / `failure` — sets the accent colour. Invalid values fail the step. |
| `facts` | no | `[]` | JSON array of `{"name","value"}` objects, rendered as a key/value block. Must be a JSON array. |
| `button-url` | no | `''` | Adds a button *and* an inline markdown link — Teams renders `potentialAction` buttons inconsistently, so the inline link is the reliable path. |
| `button-label` | no | `View` | Button label. |
| `dry-run` | no | `false` | Build and print the payload without posting. |

## Outputs

| Output | Description |
|---|---|
| `payload` | The JSON payload sent (or that would have been sent under `dry-run`). |

## Required env

| Env var | Description |
|---|---|
| `TEAMS_WEBHOOK_URL` | The incoming webhook URL. |

**Not an input, deliberately.** Per [CONTRIBUTING.md](../../CONTRIBUTING.md), secrets are
passed via `env:` at the call site so they can't leak into workflow logs through
input echoing.

## Status colours

| Status | Colour | Use for |
|---|---|---|
| `info` | `#0076D7` | Routine notices. Matches the existing PR card. |
| `success` | `#2EA043` | Completion. |
| `warning` | `#D29922` | Action starting, approval needed, deadline approaching. |
| `failure` | `#B60205` | Something broke or stalled. |

## Notes

**Non-2xx fails the step.** A revoked or rotated webhook surfaces as a red run rather
than notifications that quietly stop arriving. That matters most where this action is
used as a dead-man's switch: the value of an "operation starting" message is that
*silence afterwards* is the alarm — which only works if a broken notifier is loud.

**Notify on transitions, not on a timer.** A daily "still expiring" message trains
people to mute the channel, which defeats the purpose. Callers should track state
and post on change.

**Known duplication:** `pr-to-main-hooks.yml` posts its own Teams card with inline
bash that predates this action. Worth collapsing into this action, deliberately not
done in the same change.
