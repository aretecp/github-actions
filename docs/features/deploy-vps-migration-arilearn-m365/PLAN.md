# Migrate `arilearn-phx` and `ms-365-mcp-server` to `deploy-vps-shared.yml@v2`

Status: **Side 1 done for `ms-365-mcp-server`; `arilearn-phx` blocked on one decision**

Runbook Step 1.1 (multi-line audit) **passes for both repos** — no multi-line
values, so nothing halts the migration. Side 2 dry-export has been run; results
below.

These are the last two repos still calling `load-infisical-secrets@v1` directly
from per-repo deploy workflows. Every other consumer (`areteos`, `areteos-py`,
`bd-pulse`, `beacon`) is on `deploy-vps-shared.yml@v2`.

This is not a version bump. `@v1` is frozen deliberately and `v2`'s dotenv
render mode is a breaking major. Follow `docs/runbooks/deploy-vps-migration.md`
— Side 1 (Infisical) must land before any workflow flip, or the first v2 deploy
writes a half-empty `.env`.

## The one blocker: `MASTERY_PROJECTION_SOURCE`

`arilearn-phx` prod would **silently revert the Epic #906 mastery cutover** the
moment its shim flips.

| Source | Value |
|---|---|
| `deploy-prod.yml:106` — what prod runs today | `evidence` (hardcoded in the heredoc) |
| Infisical `/arilearn-phx` prod — what a v2 render emits | `legacy` |

Under v1 the heredoc hardcodes `evidence` and ignores the folder. Under v2 the
folder **is** the `.env`, so prod flips to `legacy` with no error and no diff in
the workflow run. This is precisely the failure the warning comment above that
line describes.

`rollback-prod.yml:68-94` omits the key entirely, by design. So the two paths
need different values, which a single folder render cannot express.

**Decision needed before flipping `arilearn-phx`.** Options:

1. Set the folder to `evidence` and have `rollback-prod.yml` override it back —
   keeps rollback's intent explicit rather than implicit in an omission.
2. Keep `rollback-prod.yml` on its own heredoc and migrate only the deploy paths.
3. Deliberately roll the mastery cutover back per the runbook — only if that is
   actually wanted, which nothing here suggests.

Nothing was changed. Setting this key either way is a behavioural decision about
mastery projection, not a migration mechanic.

## Also worth a look

The prod DB password in `/arilearn-phx` is the literal string `postgres`. It is
only reachable on the compose network (`@db/arilearn_prod`), so it is not
exposed, but it is not a password either. Unrelated to this migration; raising
it because the audit surfaced it.

## Note on verifying exports

`infisical export --format=dotenv` single-quote-wraps **every** value, including
plain ones. That is the CLI's output format, not the stored value —
`load-infisical-secrets@v2` strips them at render time (runbook Step 2.2). Do
not read those quotes as a problem, and do not assert on raw CLI output when
checking whether a secret reference expanded.

## `ms-365-mcp-server` — Side 1 complete, ready to flip

`PUBLIC_HOSTNAME` and `ENVIRONMENT` were the only two keys the folder lacked.
Both added to `/m365-mcp` prod. The folder now exports exactly the 7 keys the
heredoc writes (`VERSION` is appended at deploy time by v2):

```
MICROSOFT_CLIENT_ID  MICROSOFT_CLIENT_SECRET  MICROSOFT_TENANT_ID
MS365_MCP_SESSION_KEY  MS365_MCP_POLICY_ADMINS  PUBLIC_HOSTNAME  ENVIRONMENT
```

Dry-export diff against the heredoc: no missing keys, no extra keys. This repo
is ready for Side 3 (flip dev, verify on the VPS, then prod).

One caveat: this repo loads the shared project at `path: /` — the **root** of
`arete-shared`, not a subfolder (deploy-prod.yml:37-39). Under v2 that becomes
an explicit `extra-shared-path-*`, so enumerate what the root load is actually
supplying before narrowing it, or keys will silently vanish.

## `arilearn-phx` — 14 keys added, one decision outstanding

The folder was missing 14 of the keys the heredoc writes. All 14 added to
`/arilearn-phx` prod; values came from repo-level GitHub vars, the `production`
environment vars, and the heredoc's own constants:

| Added | Value source |
|---|---|
| `ARILEARN_LLM_MODEL`, `POOL_SIZE`, `PORT`, `POSTGRES_USER` | repo vars |
| `AWS_REGION` | repo var `AWS_SES_REGION` — **key rename**, the app reads `AWS_REGION` |
| `PHX_HOST`, `MCP_RESOURCE_URL`, `EMAIL_FROM_NAME`, `EMAIL_FROM_ADDRESS` | `production` environment vars |
| `POSTGRES_DB`, `PHX_SERVER`, `ENVIRONMENT`, `SKILL_EVIDENCE_TAXONOMY_VERSION` | heredoc constants |
| `DATABASE_URL` | Infisical secret reference — see below |

`DATABASE_URL` was composed inline from `POSTGRES_PASSWORD`, so a folder export
had no way to build it. Stored as a reference rather than a copied literal, which
keeps one source of truth for the password:

```
DATABASE_URL=ecto://postgres:${POSTGRES_PASSWORD}@db/arilearn_prod
```

Verified: the reference resolves on export.

Dry-export now returns **34 keys, zero missing**. The 6 extra keys the folder
carries beyond the heredoc — `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
`LLM_GATEWAY_KEY`, `LLM_GATEWAY_URL`, `MICROSOFT_CLIENT_SECRET_EXPIRES_AT`,
`MICROSOFT_CLIENT_SECRET_FINGERPRINT` — will land in the `.env` under v2, since
v2 renders the whole folder. Confirm the app tolerates them before flipping.

Still blocked on the `MASTERY_PROJECTION_SOURCE` decision above.

## Sequence

1. Run the Step 1.1 multi-line audit on both repos. If it trips, stop.
2. `ms-365-mcp-server` first — it is the smaller blast radius and proves the
   pattern.
3. Dry-export diff (runbook Side 2) against the current heredoc. Expect only
   `VERSION` to differ.
4. Flip dev, verify on the VPS, then prod.
5. `arilearn-phx` after m365 is stable, resolving the three landmines first.
6. Leave `rollback-prod.yml` for last in both repos.

## Explicitly not done here

No shim PRs were opened. A ready-to-merge shim is dangerous while Side 1 is
outstanding — merging it before the Infisical restructure is exactly the
half-empty `.env` failure the runbook orders against.
