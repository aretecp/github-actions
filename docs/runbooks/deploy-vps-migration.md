# Runbook: Migrate a Repo to `deploy-vps-shared.yml@v2`

This runbook is the authoritative per-repo migration sequence. It is two-sided and strictly ordered: Infisical restructure must land **before** the workflow shim is flipped, or the first v2 deploy produces a half-empty `.env`.

---

## Prerequisites

- [ ] Access to the repo's Infisical project (folder write + import management)
- [ ] A working v1 deploy in prod (something to compare against)
- [ ] `jq` installed locally for dry-export verification
- [ ] `gh` CLI auth for workflow dispatch

---

## Side 1 — Infisical restructure

Do this entirely before touching any workflow file.

### Step 1.1 — Audit for multi-line secrets

`export-as-env: dotenv` does **not** support multi-line secret values (PEM keys, certificates, base64 blobs with embedded newlines). Before proceeding:

```bash
# Export the current app folder via the Infisical CLI and scan for newlines
infisical export --projectId=<project-id> --env=<env> --path=/<app> --format=dotenv \
  | grep -P '\\n|\\\\n'
```

If any secret contains a real newline (not the escaped `\n` string), **stop migration for this repo** until those secrets are handled (split out, encoded, or replaced).

### Step 1.2 — Identify non-secret config currently in workflow vars/heredocs

The v2 pattern moves all config (including previously-hardcoded values) into Infisical so the folder export is a complete `.env`. Common values to add:

- `PHX_HOST` / `PHX_HOST_DEV`
- `EMAIL_FROM_ADDRESS`
- `ENVIRONMENT`
- `LANGFUSE_HOST`
- `AUDIT_RETENTION_DAYS`
- Any `vars.*` values interpolated into the current heredoc

Add these as plain (non-secret) values in the app folder in Infisical.

### Step 1.3 — Verify Infisical imports

The app folder should import from the shared project's relevant subfolder(s) so that `include-imports: 'true'` folds them in automatically. In the Infisical UI:

1. Open the app folder → Imports tab
2. Add an import from the shared project pointing to the shared-dep subfolder
3. Confirm the import is visible and resolves correctly

Do NOT create a separate `load-infisical-secrets` step for shared deps — the single app-folder render handles it.

### Step 1.4 — Note the infra folder

Deploy-time credentials (`TAILSCALE_AUTHKEY`, `VPS_TAILSCALE_IP`, `VPS_SSH_KEY`) live in the **`/tailscale`** folder of the shared project. Despite the name, this is the deploy credentials folder — it holds all three infra creds every consumer repo already points at. No data migration is needed; no rename planned in v2.

---

## Side 2 — Dry-export verification

Run this **after** the Infisical restructure and **before** flipping any workflow.

### Step 2.1 — Export and compare

```bash
# Export the v2 folder layout via Infisical CLI (or curl the API directly)
infisical export \
  --projectId=<app-project-id> \
  --env=<env> \
  --path=/<app-path> \
  --includeImports=true \
  --format=dotenv \
  > /tmp/v2-export.env

# Diff against the current heredoc .env (copy it into /tmp/current.env)
diff <(sort /tmp/current.env) <(sort /tmp/v2-export.env)
```

Expected: the only diff should be `VERSION` (added at deploy time, not in Infisical) and any values you intentionally moved in Step 1.2. No unexpected missing keys.

### Step 2.2 — Verify bare KEY=value output

```bash
# Confirm no quote-wrapped values (docker compose --env-file treats quotes literally)
grep '="' /tmp/v2-export.env && echo "WARNING: quoted values found" || echo "OK: bare values"
```

If the Infisical CLI wraps values in quotes, the actual `load-infisical-secrets@v2` dotenv render step strips them. Verify the render strips them correctly before deploying.

---

## Side 3 — Flip the shim (per environment, dev first)

### Step 3.1 — Write the v2 shim

Replace the existing `deploy-dev.yml` (or `deploy-prod.yml`) with a thin shim. Reference pattern:

```yaml
name: Deploy dev

on:
  workflow_dispatch:
    inputs:
      ref:
        description: Branch or tag to deploy
        required: false
        default: main

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: aretecp/github-actions/.github/workflows/deploy-vps-shared.yml@v2
    with:
      environment: dev
      infisical-identity-id: ${{ vars.INFISICAL_OIDC_IDENTITY_ID }}
      shared-project-slug: ${{ vars.INFISICAL_SHARED_PROJECT_SLUG }}
      app-project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
      env-slug: dev
      app-path: /myapp
      vps-user: ubuntu
      repo-dir: /srv/myapp
      repo-url: https://github.com/aretecp/myapp.git
      compose-file: docker-compose.dev.yml
      env-file-name: .env.dev
      ref: ${{ inputs.ref || 'main' }}
      allow-clone: true
      healthcheck-containers: myapp_app myapp_db
```

### Step 3.2 — Deploy dev and verify

1. Trigger `deploy-dev.yml` via `workflow_dispatch`.
2. Confirm the workflow completes without errors.
3. SSH into the VPS and verify:

```bash
# Check the rendered .env arrived correctly
cat /srv/myapp/.env.dev | grep -v '=' | wc -l   # should be 0 (no blank key lines)
wc -l /srv/myapp/.env.dev                         # should match expected count

# Spot-check a known secret is present and non-empty
grep 'DATABASE_URL' /srv/myapp/.env.dev | cut -d= -f1   # prints key only, not value

# Verify VERSION was appended
grep '^VERSION=' /srv/myapp/.env.dev
```

4. Confirm healthchecks pass and the app is serving traffic.

### Step 3.3 — Deploy prod (after dev is stable)

Repeat Step 3.1 for `deploy-prod.yml` with:

```yaml
      environment: prod
      env-slug: prod
      compose-file: docker-compose.prod.yml
      env-file-name: .env
      allow-clone: false    # prod refuses to clone — checkout must already exist
```

Prod shims should NOT include `allow-clone: true`. If the VPS directory is ever missing in prod, that is a human-intervention situation, not an automated recovery.

---

## Optional inputs — extra shared folders, DB backup, compose flags

### Extra shared folders in the `.env` (`extra-shared-path-1/2/3`)

The primary `app-path` (in `app-project-slug`) is always rendered into the `.env`. Repos that also need **shared** secrets in the app `.env` (e.g. areteos pulls `/teams` and `/aws/accounts/arete/ses-sender-user`) list those folders here — each is loaded from `shared-project-slug` and merged into the same `.env`:

```yaml
      app-path: /areteos                                  # primary, app-project
      extra-shared-path-1: /teams                         # shared-project
      extra-shared-path-2: /aws/accounts/arete/ses-sender-user
      # extra-shared-path-3: ...
```

Precedence: extras are merged **first**, the primary `app-path` folder **last**, so on a duplicate key the app folder wins (matches the old "app load runs last" rule). Up to 3 extra folders; all live in `shared-project-slug`. (Infisical imports on the app folder still work too, and need no input — use whichever you prefer; `extra-shared-path-*` keeps the choice visible in the workflow.)

## Optional inputs — DB backup + compose flags

### Pre-deploy DB backup (first-class, `db-type`)

The shared workflow can snapshot the live DB **before** `compose up` recreates containers, so a bad migration/recreate is recoverable. It no-ops on the first deploy (DB container not running yet) and via `skip-pre-deploy: true` (break-glass).

**SQLite** (e.g. bd-pulse — snapshot lives inside the data volume):

```yaml
      db-type: sqlite
      db-container: bd_tracker_api_dev      # the container that mounts the data volume
      db-path: /app/data/bd_tracker_dev.db
      # snapshot-dir defaults to <dirname(db-path)>/pre-deploy-snapshots
      snapshot-retention-days: 7
      skip-pre-deploy: ${{ inputs.skip_pre_deploy_checks || false }}
```

**Postgres** (e.g. areteos — `pg_dump` to a host path under `repo-dir`):

```yaml
      db-type: postgres
      db-container: areteos_db
      db-name: areteos_prod
      db-user: areteos
      # snapshot-dir defaults to <repo-dir>/pre-deploy-snapshots
      snapshot-retention-days: 7
```

> Postgres note: `pg_dump` runs via `docker exec` as `db-user` over the container's local socket. The official images use trust auth for local connections, so no password is needed — verify on first run; if your cluster requires a password, that's a follow-up (pass `PGPASSWORD` into the container).

### Compose flags

| Input | Default | When to set |
|-------|---------|-------------|
| `compose-build` | `true` | `false` only if the compose pulls pre-built images instead of building from source |
| `compose-force-recreate` | `false` | `true` if the compose uses fixed `container_name`s and you hit hash-prefixed container names on redeploy (breaks health-inspect + Traefik routing) |

> There is intentionally **no** `--remove-orphans` option. On Areté VPSes every box runs Traefik as a separate stack and dev + prod share a compose project, so `--remove-orphans` could only delete other running services. Orphan cleanup, if ever needed, is a deliberate manual operation.

---

## Worked example — areteos (multi-shared-folder + Postgres)

areteos is the case that exercises everything: it pulls SES (+ Teams in prod) from the shared project into the `.env`, and runs Postgres. These shims are copy-paste ready once v2 exists and the `/areteos` Infisical folder is restructured. `# REPLACE` marks values to confirm before flipping.

**`deploy-dev.yml`** (loads `/areteos` + shared `/ses`; clones allowed):

```yaml
name: Deploy Dev
on:
  push: { branches: [develop] }
  workflow_dispatch:
    inputs:
      branch: { description: Branch to deploy, required: false, default: develop }
permissions:
  contents: read
  id-token: write
jobs:
  deploy:
    uses: aretecp/github-actions/.github/workflows/deploy-vps-shared.yml@v2
    with:
      environment: development
      infisical-identity-id: ${{ vars.INFISICAL_OIDC_IDENTITY_ID }}
      shared-project-slug: ${{ vars.INFISICAL_SHARED_PROJECT_SLUG }}
      app-project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
      env-slug: dev
      app-path: /areteos
      extra-shared-path-1: /aws/accounts/arete/ses-sender-user   # SES → .env
      vps-user: ${{ vars.VPS_USER }}
      repo-dir: /home/sglyon/areteos   # all apps share the /home/sglyon root on the VPS
      repo-url: https://github.com/aretecp/areteos.git
      compose-file: docker-compose.dev.yml
      env-file-name: .env.dev
      ref: ${{ inputs.branch || github.ref_name }}
      allow-clone: true
      healthcheck-containers: areteos_app_dev areteos_db_dev
      db-type: postgres
      db-container: areteos_db_dev
      db-name: areteos_dev      # POSTGRES_DB_DEV default
      db-user: areteos
```

**`deploy-prod.yml`** (loads `/areteos` + shared `/teams` + `/ses`; no clone):

```yaml
name: Deploy Production
on:
  release: { types: [published] }
  push: { tags: ['v[0-9]+.[0-9]+.[0-9]+'] }
  workflow_dispatch:
    inputs:
      version: { description: "Version tag (e.g. v1.2.3); defaults to triggering ref.", required: false, type: string }
concurrency: { group: deploy-prod, cancel-in-progress: false }
permissions:
  contents: read
  id-token: write
jobs:
  deploy:
    uses: aretecp/github-actions/.github/workflows/deploy-vps-shared.yml@v2
    with:
      environment: production
      infisical-identity-id: ${{ vars.INFISICAL_OIDC_IDENTITY_ID }}
      shared-project-slug: ${{ vars.INFISICAL_SHARED_PROJECT_SLUG }}
      app-project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
      env-slug: prod
      app-path: /areteos
      extra-shared-path-1: /teams                                # Teams webhook → .env
      extra-shared-path-2: /aws/accounts/arete/ses-sender-user   # SES → .env
      vps-user: ${{ vars.VPS_USER }}
      repo-dir: /home/sglyon/areteos   # all apps share the /home/sglyon root on the VPS
      repo-url: https://github.com/aretecp/areteos.git
      compose-file: docker-compose.prod.yml
      env-file-name: .env
      ref: ${{ inputs.version || github.ref_name }}
      allow-clone: false
      healthcheck-containers: areteos_app areteos_db
      db-type: postgres
      db-container: areteos_db
      db-name: areteos_prod
      db-user: areteos
```

Notes specific to areteos:
- No `compose-force-recreate` (the old areteos deploy didn't use it; add only if you hit hash-prefixed container names).
- No `--remove-orphans` (not an option) — areteos's VPS also runs Traefik via labels (separate stack).
- Confirm the Postgres `pg_dump` auth works via `docker exec` (the image's local trust auth); if it needs a password, pass `PGPASSWORD` into the container.
- Move areteos's non-secret config (`PHX_HOST`/`PHX_HOST_DEV`, `EMAIL_FROM_ADDRESS`, `ENVIRONMENT`, `LANGFUSE_HOST`, `AUDIT_RETENTION_DAYS`) into the `/areteos` Infisical folder per Step 1.2 before flipping.

---

## Rollback

v2 deploy is currently deploy-from-scratch only. If a deploy produces a broken `.env`:

1. SSH to the VPS.
2. Restore the previous `.env` from the backup (`cp /srv/myapp/.env.bak /srv/myapp/.env`).
3. Re-run `docker compose --env-file .env -f docker-compose.prod.yml up -d`.

A `rollback-prod` workflow covering this path is a planned fast-follow to v2. See aretecp/github-actions for tracking.

---

## Checklist

```
- [ ] Step 1.1 — No multi-line secrets in app folder
- [ ] Step 1.2 — Non-secret config moved into Infisical
- [ ] Step 1.3 — Infisical imports verified
- [ ] Step 2.1 — Dry-export diff matches expectations
- [ ] Step 2.2 — Bare KEY=value confirmed (no quote wrapping)
- [ ] Step 3.1 — v2 shim written
- [ ] Step 3.2 — Dev deploy verified
- [ ] Step 3.3 — Prod deploy verified
```
