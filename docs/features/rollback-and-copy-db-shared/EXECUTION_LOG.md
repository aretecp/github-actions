# Execution Log: Rollback VPS + Copy Prod DB — Shared Reusable Workflows

## [2026-06-04] — Pre-impl audit

- **Action**: Read the full contracts for `deploy-vps-shared.yml@v2`, `bd-pulse/rollback-prod.yml`, `bd-pulse/copy-prod-db.yml`, `actions/load-infisical-secrets/action.yml`, and the `rollback-and-copy-db-shared/BRAINSTORM.md`.
- **Key findings**:
  - bd-pulse rollback uses a Docker volume + `alpine` + `python:3.12-slim` pattern for the SQLite swap — no scp, no docker cp. The volume name is hardcoded per-repo; the shared workflow must derive it dynamically via `docker inspect`.
  - bd-pulse rollback uses a hardcoded inline health loop (20 × 5s); the shared workflow replaces this with `wait-for-healthy.sh@v2` (proven in deploy).
  - bd-pulse copy-prod-db uses `docker exec` + `docker cp` for SQLite; no dev backup before clobber. The shared workflow adds the mandatory dev-backup step.
  - bd-pulse copy-prod-db does NOT load app secrets — Tailscale creds only. Confirmed copy-db shared workflow must NOT render an app .env.
  - Postgres rollback restore: bd-pulse doesn't have this (sqlite-only). The shared workflow implements it via `gunzip | pg_restore --clean --if-exists` pattern from the BRAINSTORM.
  - `docker inspect --format` with Go templates cannot safely embed shell variables in the format string. Fixed: use `docker inspect | jq -r --arg dst "$DB_DIR"` instead.
- **Result**: Two confirmed danger paths. Guards designed: `confirm==RESTORE-DB` for rollback DB restore; `confirm==CLOBBER-DEV` for copy-db. Both fail at a runner-side bash step BEFORE any SSH connection when confirm is wrong.

## [2026-06-04] — Phase 2: rollback-vps-shared.yml

- **Action**: Created `.github/workflows/rollback-vps-shared.yml`
- **Files changed**: `.github/workflows/rollback-vps-shared.yml` (new, 330 lines)
- **Decisions**:
  - Inputs are a strict superset of deploy-vps-shared inputs. Added: `version` (required), `restore-db-snapshot` (bool, default false), `confirm` (string, default ''). Removed: `ref`, `allow-clone`, `repo-url`, `skip-pre-deploy`, `snapshot-retention-days` (rollback doesn't need clone/backup, only restore).
  - `validate-db-restore-confirmation` step runs on the RUNNER (not SSH) so it fails fast before opening any Tailscale connection. Checks confirm==RESTORE-DB AND db-type != none.
  - SQLite restore derives the Docker volume name via `docker inspect "$DB_CONTAINER" | jq -r --arg dst "$DB_DIR" '.[0].Mounts[] | select(.Type == "volume" and .Destination == $dst) | .Name'`. This avoids Go-template injection of shell variables and works on stopped containers.
  - SQLite restore snapshot search: `ls -1t /data/${SNAP_DIR_IN_VOL}/pre-deploy-*.db | head -1` inside an alpine container. FAIL + `docker start $DB_CONTAINER || true` if no snapshot found (leave app on current DB rather than leave it stopped).
  - Postgres restore: `gunzip -c $SNAP | docker exec -i $DB_CONTAINER pg_restore --clean --if-exists --no-privileges --no-owner -d $DB_NAME`. Matches the pattern from bd-pulse's areteos copy-db.
  - compose up + healthcheck steps are verbatim copies from deploy-vps-shared (no changes).
  - `wait-for-healthy.sh` pinned to `@v2` hardcoded tag — same reasoning as deploy (github.ref_name resolves to caller's ref in a reusable workflow).
  - No `allow-clone` / no clone guard: rollback requires an existing checkout; if `.git` is missing the checkout step fails with a clear error.
  - `REQUIRED CALLER PERMISSIONS` header included verbatim.
- **Result**: success — actionlint clean

## [2026-06-04] — Phase 3: copy-prod-db-shared.yml

- **Action**: Created `.github/workflows/copy-prod-db-shared.yml`
- **Files changed**: `.github/workflows/copy-prod-db-shared.yml` (new, 288 lines)
- **Decisions**:
  - `confirm` is a REQUIRED input (no default) — the caller must explicitly pass it. Compare: rollback has `default: ''` because restore-db-snapshot defaults false and confirm is only checked when restore=true. copy-db always writes dev so confirm is always required.
  - `validate-confirm-input` runs on the runner before SSH for fast-fail.
  - Infisical load: shared project only, infra-path only, env-mode. No app-project-slug, no dotenv render, no VERSION append — exactly the bd-pulse copy-db pattern.
  - SQLite: `docker exec $PROD_DB_CONTAINER python -c "..."` with env vars passed via `DB_PATH=...` prefix (NOT via docker's `-e` flag — that would have required the var to already be set in the environment). The Python snippet WAL-checkpoints then `.backup()`. Same approach as bd-pulse.
  - Prod temp file cleanup: `docker exec $PROD_DB_CONTAINER rm -f /tmp/prod_snapshot_copy.db` — the only write to the prod container is in /tmp; the actual prod DB is never touched.
  - Dev backup (safety net): `docker cp $DEV_DB_CONTAINER:$DEV_DB_PATH $HOST_DEV_BACKUP` — graceful skip if dev container isn't running yet (first copy). Saves to `dev-backup-dir` (default `repo-dir/dev-db-backups`).
  - Postgres: `pg_dump -Fc` prod → gzip → host; then `gunzip | pg_restore --clean --if-exists` into dev. Dev backup via `pg_dump -Fc` of dev before restore; graceful skip if dev DB not reachable.
  - `dev-healthcheck-containers` is optional (default ''). The `if: ${{ inputs.dev-healthcheck-containers != '' }}` guard on the healthcheck step skips it cleanly for callers that don't configure healthchecks.
  - `wait-for-healthy.sh` ENV_FILE hardcoded to `$REPO_DIR/.env.dev` since copy-db doesn't render an env file. This is the convention for dev stacks on these VPSes. If a caller uses a different dev env file name this could fail — acceptable v1 tradeoff, document in PR.
  - `environment: production` note included in workflow comment to prevent confusion about write direction.
- **Result**: success — actionlint clean

## [2026-06-04] — PR #59 refinement: vps-deploy-core composite + rollback reuse

- **Action**: Created `actions/vps-deploy-core/action.yml` (new composite). Rewrote `rollback-vps-shared.yml` to call it.
- **Files changed**:
  - `actions/vps-deploy-core/action.yml` (new, 15 composite steps)
  - `.github/workflows/rollback-vps-shared.yml` (rewritten — 22 inline steps → 3 job steps + composite)
- **Decisions**:
  - Composite covers: Infisical app load (dotenv), 3 extra shared paths (conditional), merge, VERSION append, encode, infra load (env mode), Tailscale, VPS checkout, env file write, pre-deploy DB backup (skipped when `db-type=none`), `pre-compose-up-script` hook (skipped when empty), compose up, healthcheck.
  - Hook placement: after env-file write AND after pre-deploy DB backup, before compose up. Runs via `appleboy/ssh-action@v1.2.0` with `command_timeout: 10m`. Caller supplies all logic; composite just `eval`s it after `cd "$REPO_DIR"`.
  - Rollback now has 3 job steps: (1) confirm gate (runner, conditional on restore-db-snapshot), (2) build restore script (runner, writes multiline to GITHUB_OUTPUT), (3) call vps-deploy-core with `db-type: none` + `pre-compose-up-script` from step 2 output.
  - Deploy behavior unaffected: `pre-compose-up-script` defaults to empty string → `if: inputs.pre-compose-up-script != ''` skips the hook step entirely. Deploy callers that don't pass the input see no change.
  - `allow-clone: 'false'` hardcoded for rollback — rollback never clones.
  - Actionlint SC2295 fix: `${SNAP_DIR_IN_VOL#${DB_DIR}/}` → `_prefix="${DB_DIR}/"; ${SNAP_DIR_IN_VOL#"${_prefix}"}`.
- **Validation**: YAML parse clean (all 3 files). actionlint clean on both workflow files (composite skipped per spec).
- **Result**: success

## [2026-06-04] — Final summary

All Phase 2 + 3 steps complete. PLAN.md status set to Done.

**Files created**:
- `.github/workflows/rollback-vps-shared.yml`
- `.github/workflows/copy-prod-db-shared.yml`
- `docs/features/rollback-and-copy-db-shared/PLAN.md`
- `docs/features/rollback-and-copy-db-shared/EXECUTION_LOG.md`

**Not done (HARD STOP)**:
- No release/tag
- No bd-pulse shim migration (Phase 6)
- No merge to main

**Known limitations / things to confirm in pilot**:
- SQLite rollback volume detection: `docker inspect | jq` approach is new (not in bd-pulse); the DB container must mount the data dir as a named Docker volume (bind mounts will fail). Confirm bd-pulse uses a named volume.
- copy-prod-db healthcheck step hardcodes `ENV_FILE=$REPO_DIR/.env.dev` for the wait-for-healthy.sh invocation. If a consumer uses a different dev env file name, override by passing an empty dev-healthcheck-containers and doing healthcheck externally.
- Postgres rollback `pg_restore --clean` drops all objects in the target DB; the dump must have been taken from a compatible Postgres version.
- Both workflows call `@v2` actions — they must be released under the same major tag as deploy-vps-shared.
