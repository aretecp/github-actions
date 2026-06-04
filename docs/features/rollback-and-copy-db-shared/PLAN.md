# Plan: Shared rollback-vps & copy-prod-db Workflows

**Status**: In Progress
**Created**: 2026-06-04
**Last updated**: 2026-06-04

## Summary
bd-pulse, areteos, and ms-365 each carry near-identical `rollback-prod.yml` / `copy-prod-db.yml`. Build two SHAREABLE reusable workflows (`rollback-vps-shared.yml` + `copy-prod-db-shared.yml`) that **preserve the proven core behavior but genuinely improve it** — not a 1:1 copy. Success: one workflow per op serves bd-pulse (SQLite), areteos (Postgres), and ms-365 (rollback only), with four safety/versatility/DRY improvements baked in, and the just-shipped `deploy-vps-shared.yml` refactored onto a shared composite without behavior regression.

## Approach
Per BRAINSTORM **Option 2** (two siblings) **plus Option 3's composite extraction, now promoted IN scope**. The shared load→tailscale→ssh→(snapshot/restore) scaffolding is extracted into ONE composite action that deploy, rollback, and copy-db all consume — the proven VPS logic lives in exactly one place.

These are NEW reusable workflows in `github-actions`, shipped **additive as a minor on `v2`** (no new major). They reuse `load-infisical-secrets@v2` (env-mode render — **never file mode**) and `tailscale-connect@v2`, `appleboy/ssh-action` (NOT scp), base64-over-ssh env write, `/home/sglyon/<app>` repo dirs, and **no `--remove-orphans`, ever**.

**Preserve the proven core:**
- Rollback's careful DB-restore sequence: stop app container → move current DB aside as `.before-rollback-<ts>` + clear WAL/SHM → swap snapshot in → integrity-check → start.
- copy-db's prod-as-strictly-read-only: snapshot/dump only, NEVER write prod.
- v1 = plain `compose up` repos. arilearn blue/green deferred (no-op `recreate-strategy` placeholder only).

**copy-db is OPTIONAL per repo** (ms-365 has none).

### The FOUR improvements (all IN scope)
1. **Dev-backup before clobber (copy-db)** — before overwriting dev's DB with prod's, move dev's current DB aside (same move-aside pattern rollback uses) so dev data is recoverable. Closes the real gap: today dev is unprotected.
2. **Postgres support (versatility)** — both workflows handle `db-type: sqlite | postgres` from day one. SQLite = file `.backup()` / copy / move-aside; Postgres = `pg_dump` / `pg_restore` (drop+restore dev; dump prod read-only). areteos can adopt, not just bd-pulse.
3. **Confirmation gate on destructive ops** — typed-string confirm inputs. copy-db requires `confirm: CLOBBER-DEV`; rollback's DB-restore path (already opt-in via `restore-db-snapshot` boolean) ADDITIONALLY requires `confirm: RESTORE-DB`. Keep the boolean AND add the typed confirm for that path; destructive step refuses to run without the exact phrase.
4. **Shared composite (efficiency/DRY)** — extract the common scaffolding into ONE composite action (`actions/vps-deploy-core`) used by deploy + rollback + copy-db.

## Affected Files / Components
| File / Component | Change | Why |
|-----------------|--------|-----|
| `actions/vps-deploy-core/action.yml` (new) | Composite: load→tailscale→ssh-render→DB snapshot/restore primitives | One proven place for the VPS scaffolding (#4) |
| `.github/workflows/deploy-vps-shared.yml` | **Refactor** to consume the composite — behavior-preserving | DRY; deploy is the proven baseline the composite must reproduce |
| `.github/workflows/rollback-vps-shared.yml` (new) | Reusable `workflow_call` on the composite: restore sequence + boolean + typed confirm + sqlite/postgres | Shareable rollback (#2, #3) |
| `.github/workflows/copy-prod-db-shared.yml` (new) | Reusable `workflow_call` on the composite: prod read-only → dev-backup → clobber, sqlite/postgres, typed confirm | Shareable copy-db (#1, #2, #3) |
| `docs/runbooks/deploy-vps-migration.md` | Add rollback + copy-db migration sections + destructive-op runbook | Repeatable per-repo migration |
| `README.md` (line 21 table) | Two new rows at `v2` | Discoverability |
| `aretecp/bd-pulse` `rollback-prod.yml` / `copy-prod-db.yml` | Replace bodies with shims → new workflows `@v2` | Pilot migration |

Precedent to mirror: `deploy-vps-shared.yml` — `REQUIRED CALLER PERMISSIONS` header, v2 env-mode dotenv render, the `db-type` sqlite/postgres switch, and `wait-for-healthy.sh` pinned to the `v2` tag (NOT `github.ref_name`).

## Implementation Steps

### Phase 0 — Ground truth
- [x] Read the REAL bd-pulse `rollback-prod.yml` + `copy-prod-db.yml` verbatim. Capture exact step text, ordering, container/db names, snapshot dir, the `.before-rollback-<ts>` aside, integrity-check command, health loop, DESTRUCTIVE warning text.
- [x] Read areteos's `rollback-prod.yml` + `copy-prod-db.yml` / `scripts/copy-prod-db.sh` and ms-365's rollback. Capture the **postgres** dump/drop/restore sequence and the sqlite↔postgres divergence per step.
- [x] Run **pre-impl-audit** (contract-touching; this RE-TOUCHES the proven deploy): confirm the composite can reproduce deploy's exact steps before any refactor.

### Phase 1 — Composite extraction + deploy refactor (HIGHEST RISK — behavior-preserving)
- [x] Create `actions/vps-deploy-core/action.yml` (composite) factoring out the repeated VPS primitives currently inlined in `deploy-vps-shared.yml`: Infisical load(s) + merge, env render/encode, required-keys gate, tailscale-connect, checkout, base64-over-ssh env write, and the DB snapshot/restore step bodies (sqlite + postgres branches).
- [x] Refactor `deploy-vps-shared.yml` to consume the composite. The composite MUST reproduce the exact steps — same ordering, same flags, no `--remove-orphans`, `wait-for-healthy.sh` still pinned to `v2`.
- [ ] **GATE: re-verify the bd-pulse DEV deploy goes green with IDENTICAL behavior BEFORE building rollback/copy-db.** Diff the rendered `.env` byte-for-byte vs. pre-refactor output. If deploy regresses, STOP and fix before proceeding — do not build on a broken composite.

### Phase 2 — rollback-vps-shared.yml
- [ ] Create `.github/workflows/rollback-vps-shared.yml` (`workflow_call`) on the composite, with the inputs table below + `REQUIRED CALLER PERMISSIONS` header + `permissions: { id-token: write, contents: read }`.
- [ ] Compose: load app secrets + Tailscale → connect → checkout `version` tag → render `.env` (env-mode, via composite) → `git fetch --tags` / `git checkout <version>`.
- [ ] Port the preserved restore sequence, gated `if: restore-db-snapshot == true`: stop app container → find most-recent `pre-deploy-snapshots/pre-deploy-*` (FAIL if none) → move current DB aside `.before-rollback-<ts>` + clear WAL/SHM → swap snapshot in + chown → integrity-check → start. Preserve exact ordering.
- [ ] **Improvement #3**: the restore step ALSO requires `confirm == 'RESTORE-DB'`; refuse (hard-fail) if the phrase is wrong, even when `restore-db-snapshot: true`. Keep the boolean too.
- [ ] **Improvement #2**: branch the restore on `db-type` — sqlite (move-aside + file swap + integrity-check, the bd-pulse path) vs. postgres (`pg_restore` drop+restore from the dump). Validate each type's required inputs.
- [ ] `docker compose up -d --build` → existing healthcheck loop (via composite).
- [ ] Add `recreate-strategy` as a documented **no-op placeholder** for arilearn blue/green; do NOT build the script branch.

### Phase 3 — copy-prod-db-shared.yml
- [ ] Create `.github/workflows/copy-prod-db-shared.yml` (`workflow_call`) on the composite + permissions header. **No app-secret load, no `.env` render** — Tailscale creds only.
- [ ] Compose: load `/tailscale` (env-mode, job-only) → connect → SSH.
- [ ] Port prod read-only source: sqlite WAL-safe `.backup()` to temp → integrity-check → `docker cp` to host; postgres `pg_dump -Fc` (read-only). **Never write prod** — direction hard-coded, no source/target swap input.
- [ ] **Improvement #1**: BEFORE clobbering dev — move dev's current DB aside (sqlite: `.before-copy-<ts>` move-aside; postgres: `pg_dump` of dev before drop) so dev is recoverable.
- [ ] Clobber dev: stop dev api → sqlite `docker cp` snapshot into dev DB path / postgres drop+`pg_restore` → start dev api → cleanup temp → health check.
- [ ] **Improvement #3**: whole destructive run requires `confirm == 'CLOBBER-DEV'`; hard-fail otherwise.
- [ ] **Improvement #2**: branch every DB step on `db-type`; validate required inputs per type.

### Phase 4 — Docs
- [ ] Extend `docs/runbooks/deploy-vps-migration.md`: per-repo rollback + copy-db migration; how the typed-confirm gates work; the loud note that copy-db's `environment` is for OIDC claims, NOT the write target (target is DEV); how to recover from a `.before-rollback-*` / `.before-copy-*` aside.
- [ ] Add two README rows (line 21 table) at `v2`.

### Phase 5 — Release
- [ ] Cut a **minor on `v2`** per RELEASING.md (`release.yml` advances the moving `v2` tag). No new major.

### Phase 6 — bd-pulse pilot (sequenced)
- [ ] Flip `rollback-prod.yml` → shim. **Verify code-only rollback FIRST** (`restore-db-snapshot: false`): tag checkout + recreate + healthcheck; rendered `.env` matches today byte-for-byte.
- [ ] Verify guarded DB-restore (`restore-db-snapshot: true` + `confirm: RESTORE-DB`): the `.before-rollback-<ts>` aside, integrity-check, hard-fail-when-no-snapshot, AND hard-fail-on-wrong-confirm. Validate on dev data — confirm the aside is restorable BEFORE trusting the swap.
- [ ] Flip `copy-prod-db.yml` → shim. Run with `confirm: CLOBBER-DEV`: confirm prod stays read-only, the dev-backup aside lands and is restorable, and dev ends in the expected state.
- [ ] Run **compounder**: capture the behavior-preserving-composite-refactor procedure, the destructive-path verification (aside must be restorable before trusting the swap), and the sqlite↔postgres divergence as reusable patterns.

### Phase 7 — Follow-ups
- [ ] **areteos** (Postgres — exercises the pg path end-to-end): rollback + copy-db shims; standardize its copy-db `/`-root recursive Infisical load down to `/tailscale` env-mode.
- [ ] **ms-365** (rollback only, no DB) shim.
- [ ] **arilearn blue/green**: wire the `recreate-strategy: redeploy-script` branch in rollback.

## rollback-vps-shared.yml — Inputs
| Input | Purpose |
|-------|---------|
| `environment` | GH environment (OIDC claims + approval gate) — `prod` |
| `infisical-identity-id` | OIDC machine identity UUID |
| `shared-project-slug` / `app-project-slug` / `env-slug` | Infisical projects + env |
| `app-path` (+ `extra-shared-path-1..3`) | app folder → dotenv `.env` render |
| `infra-path` | Tailscale creds — default `/tailscale`, env-mode, job-only |
| `vps-user` / `repo-dir` / `compose-file` / `compose-build` / `compose-force-recreate` | VPS target + recreate flags |
| `env-file-name` | rendered env filename — default `.env` |
| `required-keys` | pre-write required-keys gate |
| `healthcheck-containers` | health loop target(s) |
| `version` | **REQUIRED** — tag to roll back to |
| `restore-db-snapshot` | boolean, default `false` — opt-in destructive restore toggle (DESTRUCTIVE warning text) |
| `confirm` | typed-string gate — restore path refuses unless `== 'RESTORE-DB'` (#3) |
| `db-type` / `db-container` / `db-path` / `db-name` / `db-user` / `snapshot-dir` | DB identity for restore — `sqlite \| postgres` (#2) |
| `recreate-strategy` | **(future, not wired)** no-op placeholder for arilearn blue/green |

No `secrets:` block — OIDC. Caller grants `id-token: write`, `contents: read`.

## copy-prod-db-shared.yml — Inputs
| Input | Purpose |
|-------|---------|
| `environment` | GH environment for OIDC claims. **WRITE target is DEV** — name is OIDC claims, NOT target. Documented loudly. |
| `infisical-identity-id` | OIDC machine identity |
| `shared-project-slug` | Infisical project for Tailscale creds load only |
| `infra-path` | Tailscale creds — default `/tailscale`, env-mode, job-only |
| `vps-user` / `repo-dir` | VPS user + dir |
| `db-type` | `sqlite \| postgres` (#2) |
| `prod-db-container` / `dev-db-container` | source (prod, read-only) + target (dev) — distinct values |
| `db-path` | sqlite: `.db` path inside the container |
| `db-name` / `db-user` | postgres: dev DB to restore + prod DB to dump |
| `dev-api-container` | dev api container to stop/start around the swap |
| `dev-backup-dir` | where dev's pre-clobber backup lands (#1) |
| `confirm` | typed-string gate — refuses unless `== 'CLOBBER-DEV'` (#3) |
| `healthcheck-containers` | post-copy health check target(s) |

No `secrets:` block — OIDC. Caller grants `id-token: write`, `contents: read`.

## Out of Scope
- arilearn blue/green redeploy logic (no-op `recreate-strategy` placeholder only; wired in Phase 7).
- A combined `vps-ops-shared.yml` operation-switch workflow (BRAINSTORM rejected).
- copy-db dry-run mode.
- Any new MAJOR version — this ships additive on `v2`.

## Risks / Tradeoffs
- **Composite refactor regressing deploy (HIGHEST RISK)**: deploy just took 9 patches to stabilize. The composite MUST be behavior-preserving. Mitigation: Phase 1 gate — re-verify bd-pulse dev deploy green + diff rendered `.env` byte-for-byte BEFORE building rollback/copy-db; STOP and fix on any regression.
- **Testing destructive paths without real data loss**: validate rollback restore AND copy-db dev-backup on bd-pulse DEV / throwaway snapshots; assert the `.before-*` aside is restorable before trusting any swap. Per Areté rules: do NOT push without manually walking both paths.
- **sqlite ↔ postgres divergence**: every DB step branches on `db-type` and validates its required inputs, or a postgres caller silently runs the sqlite path. v1 proves sqlite (bd-pulse); postgres proven in Phase 7 (areteos).
- **Typed-confirm false safety**: a confirm gate that's evaluated AFTER the destructive command is useless. Gate must hard-fail at step entry, before any write.
- **copy-db `environment` name misleading** — grants OIDC claims but WRITES dev. Mitigation: documented loudly in inputs + runbook.
- **No `--remove-orphans`, ever** — carried from deploy (shared VPS / Traefik).

## Open Questions
- [ ] Confirm the refactored composite reproduces deploy's rendered `.env` exactly (Phase 1 gate).
- [ ] Postgres rollback/copy ordering — verify against areteos's actual `prod.yml` + `scripts/copy-prod-db.sh` in Phase 0; spec the bd-pulse sqlite order now, prove pg in Phase 7.
- [ ] Composite versioning surface — does `vps-deploy-core` get its own `@vN`, or ride the workflow `v2` tag? Decide in Phase 1.

## Skills / Agents to Use
- **pre-impl-audit**: Phase 0, before any refactor — contract-touching AND re-touches the proven deploy. Confirm the composite can reproduce deploy's exact steps and that the new inputs match the REAL bd-pulse/areteos workflows before writing YAML.
- **compounder**: after the bd-pulse pilot (Phase 6) — capture the behavior-preserving composite-refactor procedure, the destructive-path verification (aside must be restorable before trusting the swap), and the sqlite↔postgres divergence as reusable patterns.
