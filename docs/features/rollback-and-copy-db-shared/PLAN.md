# Plan: Rollback VPS + Copy Prod DB — Shared Reusable Workflows

**Status**: Done
**Created**: 2026-06-04
**Last updated**: 2026-06-04

---

## Context

Two net-new reusable `workflow_call` workflows that extend the VPS deploy tooling:

- `rollback-vps-shared.yml` — roll back to a previous version tag; optionally restore the pre-deploy DB snapshot (sqlite or postgres).
- `copy-prod-db-shared.yml` — copy the PROD database to DEV (read-only prod access; typed-confirm-gated clobber of dev).

Phases 0 + 1 (the `vps-deploy-core` composite and `deploy-vps-shared.yml` refactor) are complete and merged at `v2`.

---

## Prior art / grounding

- `bd-pulse/.github/workflows/rollback-prod.yml` — proven SQLite swap sequence.
- `bd-pulse/.github/workflows/copy-prod-db.yml` — proven WAL-safe prod read + dev clobber.
- `deploy-vps-shared.yml@v2` — reference for input shape, Infisical load pattern, tailscale, env render, ssh-action usage, compose-up flags.

---

## Phases

### Phase 2 — `rollback-vps-shared.yml`

- [x] Create `.github/workflows/rollback-vps-shared.yml`
  - Inputs mirror deploy-vps-shared (environment, infisical identity/project-slugs, env-slug, app-path, extra-shared-path-1/2/3, infra-path, vps-user, repo-dir, compose-file, env-file-name, healthcheck-containers, compose-build, compose-force-recreate, db-type, db-container, db-path, db-name, db-user, snapshot-dir)
  - Net-new inputs: `version` (required), `restore-db-snapshot` (boolean, default false), `confirm` (string — must equal `RESTORE-DB` when restore-db-snapshot=true)
  - Step order: load app secrets → load extra shared → merge → append VERSION → encode → load infra → tailscale → checkout tag on VPS → write .env → (if restore-db-snapshot=true AND confirm==RESTORE-DB): DB restore → compose up → healthcheck
  - SQLite restore: stop container → find latest pre-deploy-*.db (FAIL if none) → move aside .before-rollback-<ts> + clear WAL/SHM → copy + chown → integrity-check
  - Postgres restore: find latest pre-deploy-*.sql.gz (FAIL if none) → drop/restore via pg_restore
  - Confirmation gate: if restore-db-snapshot=true but confirm != RESTORE-DB → FAIL with clear error before touching DB
- [x] Validate with actionlint

### Phase 3 — `copy-prod-db-shared.yml`

- [x] Create `.github/workflows/copy-prod-db-shared.yml`
  - Inputs: environment, infisical-identity-id, shared-project-slug, infra-path, vps-user, repo-dir, db-type (sqlite|postgres), prod-db-container, dev-db-container, prod-db-path/dev-db-path (sqlite) or db-name+db-user (postgres), prod-compose-file, dev-compose-file, dev-backup-dir, `confirm` (required — must equal `CLOBBER-DEV`)
  - NO app-secret load, NO .env render — tailscale creds only
  - Behavior (sqlite): WAL-safe `.backup()` of prod → integrity-check → back up dev db aside (move-aside safety net) → stop dev app container → copy prod snapshot into dev db path → start dev app → cleanup → healthcheck
  - Behavior (postgres): `pg_dump -Fc` prod (read-only, never write) → dump dev aside first → drop + restore dev
  - Guard: if confirm != CLOBBER-DEV → FAIL before any DB operation
  - NEVER write to prod container
- [x] Validate with actionlint

---

## Constraints (inherited from deploy)

- `load-infisical-secrets@v2` env-mode (never file)
- `tailscale-connect@v1`
- `appleboy/ssh-action@v1.2.0` (not scp)
- No `--remove-orphans`
- Paths follow `/home/sglyon/<app>` convention
- `wait-for-healthy.sh@v2` for healthchecks (pinned tag, not github.ref_name)

---

## Open Questions

None — all resolved by the task specification.

---

## Skills / Agents to Use

- pre-impl-audit (destructive DB contracts)
- infra-specialist
- actionlint validation

---

## Out of Scope

- Phase 4+: release tagging / bd-pulse shim migration — HARD STOP after Phase 3
- arilearn blue/green escape hatch — deferred to fast-follow
