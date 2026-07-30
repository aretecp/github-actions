# Runbook: Entra Secret Detector

Daily read-only scan of every app registration in the Entra tenant, reporting any
credential nearing expiry.

**Workflow:** [`.github/workflows/entra-secret-detector.yml`](../../.github/workflows/entra-secret-detector.yml)
**Scan logic:** [`scripts/entra-credential-scan.sh`](../../scripts/entra-credential-scan.sh)
**Schedule:** `17 13 * * *` (daily, 13:00 UTC)
**Design doc:** `docs/features/entra-secret-rotation/PLAN.md` in `aretecp/microsoft-entra-terraform-infrastructure`

## Why this exists

On 2026-07-29 arilearn prod auth broke with `AADSTS7000222` — an expired client
secret. The secret had been created by hand in the portal, was tracked by nothing,
and no system was watching it.

Every Terraform-managed secret in the tenant is on a 365-day fuse, and because the
module sets `lifecycle { ignore_changes = [end_date] }`, `terraform plan` will never
warn about an approaching expiry either. Before this workflow, nothing in the
organisation had visibility into credential expiry.

## Prerequisites

**No app-specific repo variables.** The Terraform workspace publishes
`MICROSOFT_CLIENT_ID` and `MICROSOFT_TENANT_ID` to `/entra-secret-monitor/` (prod,
internal project) on apply, and this workflow reads them with
`load-infisical-secrets` — the same pattern every other workflow uses.

There is no `MICROSOFT_CLIENT_SECRET` in that folder by design. The app has none.

Two things must be true:

1. The org-standard variables exist on this repo: `INFISICAL_OIDC_IDENTITY_ID` and
   `INFISICAL_INTERNAL_PROJECT_SLUG` (`gh variable list`).
2. Tenant admin consent has been granted for `Application.Read.All` on the **Entra
   Secret Monitor** app. See `apps/entra_secret_monitor/POST-APPLY.md` in the
   Terraform repo.

## How auth works

There is **no client secret anywhere in this flow**, by design — a
credential-expiry watchdog holding an expiring credential dies exactly the death it
exists to prevent.

1. GitHub mints a short-lived OIDC JWT for the run, audience `api://AzureADTokenExchange`.
2. Entra accepts that JWT as a `client_assertion` in place of a client secret.
3. The resulting Graph token is used for one read-only query.

The federated credential's subject is pinned to
`repo:aretecp/github-actions:ref:refs/heads/main`.

## Reading the output

Every run writes a table to the job summary. It is **silent when nothing is in
window** — no issue, no notification. A job that's green 360 days a year is a job
nobody reads, so it only speaks up when there's something to say.

| Condition | Behaviour |
|---|---|
| Nothing in window | Job summary only. Closes any open tracking issue. |
| Something within 30 days | Opens or **edits in place** a single issue labelled `entra-secret-expiry` |
| Something already expired | Same, plus the run **fails** — something is broken in prod now, not approaching a deadline |

The issue is reused and edited rather than recreated, otherwise a daily cron
accumulates 30 duplicates.

## Teams notifications

Posts to the existing PR-notify channel (`arete-shared/prod/teams/pr-notify`) via
[`actions/teams-notify`](../../actions/teams-notify). Reusing the channel the team
already watches is the point — a GitHub issue nobody has open is not a notification.

**Fires on state change only, never on a timer.** The report embeds a
`<!-- detector-state: <hash> -->` marker in the tracking issue; the next run compares
against it. The hash covers each in-window credential's `keyId` *and* whether it has
expired, so:

| Situation | Behaviour |
|---|---|
| Same credentials, a day closer | Issue edited quietly. **No Teams post.** |
| A new credential enters the window | Posts (warning) |
| One tips from expiring into expired | Posts (failure) — the hash changes even though the credential set didn't |
| Everything leaves the window | Posts "all clear" (success), closes the issue |

A daily "still expiring" message would get the channel muted, which defeats the
entire purpose. That's why the transition check exists rather than posting every run.

### Why this is a dead-man's switch

Once the rotator lands, its Teams message says *what is about to happen* — so
**silence afterwards is itself the alarm**. That's strictly better than
notify-on-failure: a pipeline that dies before reaching its error handler never sends
a failure message at all, and you'd read the silence as success.

It only works if a broken notifier is loud, which is why `teams-notify` fails the
step on any non-2xx webhook response. A revoked webhook shows up as a red run rather
than notifications that quietly stopped arriving.

The "starting" message also gives the team a **veto window** — if it lands during a
release or an incident, cancel the workflow run. Nothing has changed at that point.

### "Managed by TF: **no**"

The credential isn't named `terraform-managed-*`, so it was created out of band and
**the rotation pipeline cannot rotate it**. This is the class of credential that
broke arilearn. Either bring it under Terraform (`manage_secret = true` on the app)
or retire it.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `403 Authorization_RequestDenied` | Admin consent not granted. The token exchange *succeeds* without consent — only the Graph call fails, so this is the expected symptom of an unconsented app. | `az ad app permission admin-consent --id <monitor client id>` |
| `AADSTS700213` on token exchange | No federated identity record matched this run's subject. Expected when running from a branch — the credential is pinned to `refs/heads/main`. | Run on `main`, or add a temporary branch-scoped federated credential |
| `401` from Graph | Token rejected | Check the federated credential's subject matches the workflow's ref |
| `vars.* must be set` | Repo variables missing | See Prerequisites above |
| Workflow silently stops running | GitHub disables scheduled workflows in repos with **no activity for 60 days**. Not a live risk for this repo, but it is a silent failure mode. | Push any commit, re-enable in the Actions tab |

## Manual runs

`workflow_dispatch` accepts:

- `window-days` — preview a wider or narrower window without editing the workflow
- `dry-run` — report to the job summary only, never touch issues

Useful for confirming behaviour without waiting for the cron, or checking runway
across the fleet ahead of a planned rotation.

## Known constraint for the rotator (phase 3)

`GITHUB_TOKEN` **cannot trigger other workflows** — GitHub blocks that to prevent
recursion, so a `workflow_dispatch` sent with it silently produces no run. The
rotator therefore cannot fan out to consumer deploys using the default token. The
options, in preference order:

1. A GitHub App installation token scoped to `actions: write` on consumer repos —
   short-lived, auditable, no long-lived PAT.
2. A fine-grained PAT stored in Infisical. Simpler, but it's a long-lived credential
   in a system built to eliminate long-lived credentials, and it will itself expire.

Calling the rotator as a reusable workflow (`uses:`) sidesteps the problem *within*
this repo, but consumer deploys live in other repos, so cross-repo dispatch is
unavoidable there.
