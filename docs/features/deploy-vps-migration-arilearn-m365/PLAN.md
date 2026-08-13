# Migrate `arilearn-phx` and `ms-365-mcp-server` to `deploy-vps-shared.yml@v2`

Status: **Draft — blocked on Infisical write access**

These are the last two repos still calling `load-infisical-secrets@v1` directly
from per-repo deploy workflows. Every other consumer (`areteos`, `areteos-py`,
`bd-pulse`, `beacon`) is on `deploy-vps-shared.yml@v2`.

This is not a version bump. `@v1` is frozen deliberately and `v2`'s dotenv
render mode is a breaking major. Follow `docs/runbooks/deploy-vps-migration.md`
— Side 1 (Infisical) must land before any workflow flip, or the first v2 deploy
writes a half-empty `.env`.

## Blocker

Side 1 needs write access to the Infisical folders plus import management. The
audit in runbook Step 1.1 has **not** been run for either repo — it is the gate
that can halt the migration outright, since `export-as-env: dotenv` cannot carry
multi-line values. Run it first:

```bash
infisical export --projectId=<uuid> --env=prod --path=/arilearn-phx \
  --format=dotenv | grep -P '\\n|\\\\n'
```

Note `--projectId` takes the project UUID, not the `arete-internal` slug that
the repo variables hold.

## `ms-365-mcp-server` — straightforward

Current `.env` (deploy-prod.yml:78-88) is 5 secrets plus 2 constants:

| Key | Source today | Action |
|---|---|---|
| `MICROSOFT_CLIENT_ID` / `_SECRET` / `_TENANT_ID` | Infisical `/m365-mcp` | none |
| `MS365_MCP_SESSION_KEY` | Infisical `/m365-mcp` | none |
| `MS365_MCP_POLICY_ADMINS` | Infisical `/m365-mcp` | none |
| `PUBLIC_HOSTNAME` | hardcoded `m365.mcp.areteintelligence.ai` | add to Infisical |
| `ENVIRONMENT` | hardcoded `production` | add to Infisical |
| `VERSION` | deploy-time | handled by v2 |

One caveat: this repo loads the shared project at `path: /` — the **root** of
`arete-shared`, not a subfolder (deploy-prod.yml:37-39). Under v2 that becomes
an explicit `extra-shared-path-*`, so enumerate what the root load is actually
supplying before narrowing it, or keys will silently vanish.

## `arilearn-phx` — three landmines

Current `.env` (deploy-prod.yml:75-112) is 30 keys. Three do not survive a naive
folder export:

**1. `AWS_REGION` is a key rename.** The workflow writes
`AWS_REGION=${{ vars.AWS_SES_REGION }}`. The GitHub variable is `AWS_SES_REGION`;
the app reads `AWS_REGION`. Store it in Infisical under the name the app reads.

**2. `DATABASE_URL` is composed, not stored.** It is built inline from
`POSTGRES_PASSWORD`:
`ecto://postgres:${POSTGRES_PASSWORD}@db/arilearn_prod`. A folder export has no
way to compose it — store the assembled value, or use an Infisical secret
reference.

**3. `MASTERY_PROJECTION_SOURCE` differs between deploy and rollback.**
`deploy-prod.yml` sets it to `evidence` and carries an explicit warning (Epic
#906): a prod deploy MUST keep it, or the regenerated `.env` silently reverts
mastery reads to legacy. `rollback-prod.yml:68-94` omits it **by design**.

A single shared render emits the same folder for both paths, which erases that
asymmetry. Resolve before flipping rollback — options: keep rollback on its own
heredoc, or have rollback override the key explicitly. Do not let the shared
render decide it silently.

Eight further values move from GitHub `vars` into Infisical per runbook Step
1.2: `PHX_HOST`, `PORT`, `MCP_RESOURCE_URL`, `ARILEARN_LLM_MODEL`,
`EMAIL_FROM_NAME`, `EMAIL_FROM_ADDRESS`, `POOL_SIZE`, plus the `AWS_REGION`
rename above. Constants `POSTGRES_USER`, `POSTGRES_DB`, `PHX_SERVER`,
`ENVIRONMENT`, `SKILL_EVIDENCE_TAXONOMY_VERSION` also need to exist in the
folder.

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
