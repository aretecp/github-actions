# Execution Log: Shared rollback-vps & copy-prod-db Workflows

---

## 2026-06-04 — Phase 0: Ground Truth + Pre-impl Audit

### Action
Read all real rollback/copy-db workflows across bd-pulse, areteos, ms-365 verbatim. Ran
pre-impl-audit mapping deploy-vps-shared.yml step-by-step to confirm the composite can
reproduce each step exactly.

### Files read (read-only)
- `/Users/dom/dev/arete/bd-pulse/.github/workflows/rollback-prod.yml`
- `/Users/dom/dev/arete/bd-pulse/.github/workflows/copy-prod-db.yml`
- `/Users/dom/dev/arete/areteos/.github/workflows/rollback-prod.yml`
- `/Users/dom/dev/arete/areteos/.github/workflows/copy-prod-db.yml`
- `/Users/dom/dev/arete/areteos/scripts/copy-prod-db.sh`
- `/Users/dom/dev/arete/ms-365-mcp-server/.github/workflows/rollback-prod.yml`
- `/Users/dom/dev/arete/github-actions/.github/workflows/deploy-vps-shared.yml`
  (read from `fix/required-keys-gate-and-graceful-backup` — one commit ahead of main;
   this is the v2.1.0 baseline bd-pulse runs in prod)

---

### Phase 0 Findings

#### bd-pulse `rollback-prod.yml` — exact behavior

- Infisical loads: `@v1`, `load-infisical-secrets` twice:
  1. App secrets: `project-slug: INFISICAL_INTERNAL_PROJECT_SLUG`, `path: /bd-pulse`, env-mode (no export-as-env field — v1 default is env-mode)
  2. Infra/Tailscale: `project-slug: INFISICAL_SHARED_PROJECT_SLUG`, `path: /tailscale`, `recursive: true`, env-mode
- tailscale-connect@v1
- One monolithic `appleboy/ssh-action@v1` step (NOT v1.2.0) — contains ALL of: env write + checkout + optional DB restore + compose up + health loop
- **Env write (inline heredoc — NOT base64-over-ssh)**:
  - `cat > .env << 'ENVEOF'` with hardcoded secrets interpolated via `${{ env.KEY }}`
  - Sets: MICROSOFT_CLIENT_ID, MICROSOFT_TENANT_ID, MICROSOFT_CLIENT_SECRET, CLIENT_STATE_SECRET, ANTHROPIC_API_KEY, AUTH_SECRET, NOTION_TOKEN, BD_MAILBOX, WEBHOOK_BASE_URL, DB_PATH, ADMIN_EMAILS, ACTIVE_USERS, VERSION
- `git fetch origin --tags && git checkout "$VERSION"` (no --force)
- **DB restore sequence (if `restore_db_snapshot == true`)**:
  1. `docker stop bd_tracker_api` (graceful, `|| echo` on failure)
  2. Find snapshot: `docker run --rm -v bd-tracker_bd-data:/data alpine sh -c 'ls -1t /data/pre-deploy-snapshots/pre-deploy-*.db 2>/dev/null | head -1'`
  3. FAIL if no snapshot: restart api, exit 1
  4. Move-aside + WAL clear: `docker run --rm -v bd-tracker_bd-data:/data alpine sh -c` — moves `bd_tracker.db → bd_tracker.db.before-rollback-${TS}`, rm WAL/SHM, `cp ${SNAP} /data/bd_tracker.db`, `chown 1000:1000`
  5. Integrity check: `docker run --rm -v bd-tracker_bd-data:/data python:3.12-slim python -c` — PRAGMA integrity_check, assert "ok"
- `docker compose up -d --build` (NO `--env-file` flag, NO `compose-file` flag — uses default docker-compose.yml)
- Health loop: custom `for i in $(seq 1 20)` loop, 5s sleep, 100s total — checks `bd_tracker_api` + `bd_tracker_dashboard`. NOT using wait-for-healthy.sh
- Container names: `bd_tracker_api`, `bd_tracker_dashboard`
- Volume name: `bd-tracker_bd-data`
- DB path inside container (via volume): `/data/bd_tracker.db`
- Snapshot dir: `/data/pre-deploy-snapshots/`
- Repo dir: `/home/sglyon/bd-pulse` (hardcoded)
- VPS user: `vars.VPS_USER`

#### bd-pulse `copy-prod-db.yml` — exact behavior

- Infisical: tailscale only (`path: /tailscale`, `recursive: true`, `@v1`)
- tailscale-connect@v1
- One `appleboy/ssh-action@v1` step with:
  1. WAL-safe backup: `docker exec bd_tracker_api python -c "... sqlite3 backup to /tmp/bd_prod_snapshot.db"`
  2. Integrity check: `docker exec bd_tracker_api python -c "... PRAGMA integrity_check"`
  3. `docker cp bd_tracker_api:/tmp/bd_prod_snapshot.db /tmp/bd_prod_snapshot.db`
  4. `docker compose -f docker-compose.dev.yml stop bd-tracker-api-dev`
  5. `docker cp /tmp/bd_prod_snapshot.db bd_tracker_api_dev:/app/data/bd_tracker_dev.db`
  6. `docker compose -f docker-compose.dev.yml start bd-tracker-api-dev`
  7. Cleanup: `docker exec bd_tracker_api rm /tmp/...`, `rm -f /tmp/...`
  8. Health: `sleep 10 && docker compose -f docker-compose.dev.yml ps bd-tracker-api-dev`
- No dev backup/move-aside before clobber (gap the plan addresses as improvement #1)
- No typed confirm gate (gap the plan addresses as improvement #3)
- Containers: prod=`bd_tracker_api`, dev=`bd_tracker_api_dev`, dev db path=`/app/data/bd_tracker_dev.db`

#### areteos `rollback-prod.yml` — Postgres divergence

- Infisical: 4 loads at `@v1` (tailscale, /teams, /aws/accounts/arete/ses-sender-user, /areteos app)
- tailscale-connect@v1
- One `appleboy/ssh-action@v1` step, `command_timeout: 15m`
- Env write: inline heredoc `cat > .env <<'ENVEOF'` with all Postgres secrets, `chmod 600 .env`
- `git fetch origin --tags && git checkout "$VERSION"`
- `docker compose --env-file .env -f docker-compose.prod.yml up -d --build`
- Healthcheck: `wait-for-healthy.sh` fetched from `v1` (NOT v2), with `TIMEOUT_SECONDS=150 LOG_TAIL=100`, checks `areteos_app areteos_db`
- **No DB rollback step at all** — areteos rollback is code-only
- Repo dir: `$HOME/areteos`
- **Postgres containers**: `areteos_db` (prod), `areteos_db_dev` (dev)

#### areteos `copy-prod-db.yml` + `scripts/copy-prod-db.sh` — Postgres sequence

- Infisical: single load `path: /`, `recursive: true` (the "greedy root" pattern noted as a gap to fix in Phase 7)
- Sequence via external script `scripts/copy-prod-db.sh`:
  1. `pg_dump -U $PG_USER -Fc -d $PROD_DB -f /tmp/areteos_prod_snapshot.dump` inside `areteos_db`
  2. `docker cp areteos_db:/tmp/... /tmp/...` to host
  3. `docker cp /tmp/... areteos_db_dev:/tmp/...` into dev container
  4. `docker compose -f docker-compose.dev.yml stop app-dev`
  5. `DROP DATABASE IF EXISTS $DEV_DB WITH (FORCE)` via `psql`
  6. `CREATE DATABASE $DEV_DB OWNER $PG_USER`
  7. `pg_restore -U $PG_USER -d $DEV_DB --no-owner --no-privileges $DUMP`
  8. `docker compose -f docker-compose.dev.yml start app-dev`
  9. Cleanup dump files
- No dev backup before drop (gap addressed as improvement #1 for postgres)
- Has interactive confirm (CI env var skips it) — no typed-string gate

#### ms-365-mcp-server `rollback-prod.yml`

- Infisical: 2 loads at `@v1` (shared root `/` recursive, app `/m365-mcp`)
- Code-only rollback (no DB — ms-365 has no persistent DB)
- `git checkout --force --detach "$VERSION"` (detached HEAD explicitly)
- `docker compose --env-file .env -f docker-compose.prod.yml up -d --build`
- wait-for-healthy.sh from `v1`, checks `m365_mcp`
- Repo dir: `$HOME/ms-365-mcp-server`

#### SQLite ↔ Postgres divergence summary

| Aspect | bd-pulse (SQLite) | areteos (Postgres) |
|--------|------------------|--------------------|
| Snapshot method | Python `sqlite3.backup()` WAL-safe inside container | `pg_dump -Fc` inside container |
| Snapshot location | Inside container on data volume | Host filesystem (via `docker cp`) |
| Integrity check | `PRAGMA integrity_check` via Python | `pg_isready` (deploy); none on copy |
| Rollback restore | Stop api → move-aside → cp snapshot → chown → integrity-check → start | No rollback restore implemented |
| Copy-db target write | `docker cp` snapshot into dev container path | Drop+recreate DB + `pg_restore` |
| Dev backup before clobber | None (gap #1) | None (gap #1) |
| Health wait | Custom 20×5s loop | `wait-for-healthy.sh` from v1 |

---

### Pre-impl Audit: deploy-vps-shared.yml → vps-deploy-core composite

Mapping every step of `deploy-vps-shared.yml` (v2.1.0 on `fix/required-keys-gate-and-graceful-backup`):

| # | Step name | Reproducible in composite? | Notes |
|---|-----------|---------------------------|-------|
| 1 | Load app secrets (dotenv mode) | Yes — composite input → `uses: load-infisical-secrets@v2` with `export-as-env: dotenv`, `dotenv-output-path: ${{ runner.temp }}/${{ inputs.env-file-name }}` | Output step-id `load-app-secrets` referenced in subsequent steps |
| 2 | Load extra shared folder 1 | Yes — composite conditional step, `if: inputs.extra-shared-path-1 != ''` | |
| 3 | Load extra shared folder 2 | Yes | |
| 4 | Load extra shared folder 3 | Yes | |
| 5 | Merge extra shared folders | Yes — bash step with same env vars | Primary app folder written LAST → wins on collision |
| 6 | Append VERSION to dotenv file | Yes — bash step | Must keep `VERSION="$REF"` verbatim; no masking |
| 7 | Assert required keys present | Yes — conditional `if: inputs.required-keys != ''` | grep logic preserved exactly |
| 8 | Encode rendered env (base64 -w0) | Yes — bash step, output `b64`, `::add-mask::` | Step id `encode-env` must be preserved |
| 9 | Load infra secrets (env mode) | Yes — `export-as-env: 'true'`, `recursive: 'true'`, infra-path input | Yields `TAILSCALE_AUTHKEY`, `VPS_TAILSCALE_IP`, `VPS_SSH_KEY` into job env |
| 10 | Connect to Tailscale | Yes — `uses: tailscale-connect@v1` | NOTE: deploy uses `@v1`, not `@v2` — must preserve |
| 11 | Prepare repo checkout on VPS | Yes — `appleboy/ssh-action@v1.2.0` | allow-clone gate, git fetch --prune --tags --force, symbolic-ref pull logic |
| 12 | Write env file to VPS | Yes — `appleboy/ssh-action@v1.2.0`, base64 decode, chmod 600, empty-check | |
| 13 | Pre-deploy DB backup | Yes — conditional `if: db-type != 'none' && !skip-pre-deploy`, sqlite + postgres branches | Graceful skip when container not cleanly "running" (inspect state check) |
| 14 | Docker Compose up | Yes — `appleboy/ssh-action@v1.2.0`, UP_FLAGS assembly, NO `--remove-orphans` | |
| 15 | Wait for containers healthy | Yes — `appleboy/ssh-action@v1.2.0`, `wait-for-healthy.sh` pinned to `v2` | CRITICAL: must NOT use `github.ref_name` |

**Key constraints confirmed for composite:**
- `tailscale-connect@v1` (NOT v2) — that's what deploy currently uses
- `load-infisical-secrets@v2` — already the version in deploy
- `appleboy/ssh-action@v1.2.0` — exact pin, NOT bare `@v1`
- wait-for-healthy.sh pinned to literal `v2` tag
- env-mode render (NOT file-mode) — `export-as-env: 'true'` for infra, `export-as-env: dotenv` for app
- NO `--remove-orphans` anywhere
- `base64 -w0` (Linux flag) for single-line encode
- Infra load is a separate step AFTER dotenv encode (infra creds never enter dotenv)
- Graceful backup skip uses `docker inspect -f '{{.State.Status}}'` (not `docker ps | grep`)
- Step ordering matters: checkout BEFORE env write (the comment in deploy explains why)

**Gap identified**: Composite actions cannot use `uses:` for inner actions with relative paths when the composite itself is in the same repo — they MUST use the full `aretecp/github-actions/actions/...@vN` form. The existing `load-infisical-secrets` and `tailscale-connect` composites already use this form externally. The new composite will do the same.

**Composite versioning decision**: `vps-deploy-core` rides the `v2` tag (same as the workflow). No separate versioning surface — it's an internal implementation detail of the shared workflow suite, not a standalone action callers pin directly.

**Baseline to preserve**: `fix/required-keys-gate-and-graceful-backup` — Phase 1 branch from here. The required-keys gate and graceful backup skip (inspect-state check) are already tested logic that must be preserved exactly in the composite.

### Result: PASS — composite can reproduce all 15 steps exactly with no behavior gaps

---

## 2026-06-04 — Phase 1: Composite Extraction + Deploy Refactor

### Action
Created `actions/vps-deploy-core/action.yml` composite, refactored `deploy-vps-shared.yml`
to consume it. Validated YAML + actionlint on both files.

### Files changed
- `actions/vps-deploy-core/action.yml` (new)
- `.github/workflows/deploy-vps-shared.yml` (refactored)

### Decisions
- Branched from `fix/required-keys-gate-and-graceful-backup` (not main) — this is the
  v2.1.0 baseline (required-keys gate + graceful backup skip) that bd-pulse runs in prod.
  PR targets main and includes those fixes; they need review anyway.
- `tailscale-connect@v1` preserved (deploy uses v1, not v2).
- `appleboy/ssh-action@v1.2.0` preserved (exact pin).
- `wait-for-healthy.sh` still fetches from literal `v2` tag.
- Composite inputs are a 1:1 pass-through of deploy's inputs — no new inputs, no removed
  inputs, no default changes.
- Infra load step kept OUTSIDE the composite (job-level step in the workflow) because
  composite actions cannot export env vars to the parent job's env context the same way
  — the infra env vars (TAILSCALE_AUTHKEY, VPS_TAILSCALE_IP, VPS_SSH_KEY) must land in
  `env` context of the job that the ssh-action steps read them from.
  **Correction on re-audit**: composite steps CAN set env via `echo "VAR=val" >> $GITHUB_ENV`
  and those flow back to the parent job. HOWEVER: keeping the infra load in the composite
  is cleaner since all VPS steps are in the composite and they all need VPS_TAILSCALE_IP /
  VPS_SSH_KEY. The composite is the right place.
- All SSH steps use `${{ inputs.vps-host }}` and `${{ inputs.vps-ssh-key }}` as composite
  inputs that the infra load step sets via GITHUB_ENV before the composite is called. This
  is the pattern that keeps the composite stateless w.r.t. Infisical.

### Result: success

**Validation:**
- `python3 yaml.safe_load` on both files: valid
- actionlint on `deploy-vps-shared.yml`: clean (0 errors)
- actionlint on `actions/vps-deploy-core/action.yml`: expected "not a workflow" errors only (composite action format, not a workflow file — this is correct)
- Composite: 15 steps confirmed via structured parse, matching 1:1 with original
- Input pass-through: 28 inputs forwarded; `environment` correctly stays at job level only (used by `environment:` key, not needed inside composite)
- Python heredoc indentation: PYEOF terminator at same indent as body lines in both original and composite — Python arrives at VPS at column 0 in both cases

**PR:** https://github.com/aretecp/github-actions/pull/58 (base: main)

**Open Question resolutions (from PLAN.md):**
- Composite reproduces rendered .env exactly: structurally confirmed by step-by-step audit; runtime confirmation is the Phase 1 gate (bd-pulse DEV deploy re-verification after merge)
- Composite versioning: rides the `v2` tag — it's an internal implementation detail, not a standalone action callers pin
- Postgres rollback/copy ordering: captured from areteos source in Phase 0; bd-pulse sqlite order proven; areteos pg verified in Phase 7
