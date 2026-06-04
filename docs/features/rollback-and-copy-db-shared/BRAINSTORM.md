# Brainstorm: Shared rollback-prod & copy-prod-db workflows

**Status**: Draft
**Created**: 2026-06-04
**Topic**: Convert per-repo `rollback-prod.yml` and `copy-prod-db.yml` into shared reusable workflow(s) under `aretecp/github-actions`, following the `deploy-vps-shared.yml@v2` pattern.

---

## What these workflows actually do today (grounding)

Read from bd-pulse, areteos, arilearn-phx, ms-365-mcp-server. Common scaffolding (load Infisical → tailscale-connect → ssh-action) is identical to deploy. The meaningful per-repo variation:

### rollback-prod
| Repo | Recreate mechanism | DB restore? | Env render |
|------|--------------------|-------------|------------|
| bd-pulse | `docker compose up -d --build` + inline 20-attempt health loop | **Yes, opt-in** `restore_db_snapshot` — destructive SQLite swap from `pre-deploy-snapshots/`, moves current DB aside as `.before-rollback-<ts>` | heredoc `.env` |
| areteos | `compose --env-file .env -f prod.yml up -d --build` + `wait-for-healthy.sh@v1` | No | heredoc `.env` (3 shared loads + app) |
| arilearn-phx | `scripts/blue_green_deploy.sh redeploy` (NOT plain compose; NOT `rollback`) | No | heredoc `.env` |
| ms-365 | `compose --env-file .env up -d --build` + `wait-for-healthy.sh@v1` | No | heredoc `.env` |

Rollback today is **deploy-at-a-previous-tag**. ~95% identical to `deploy-vps-shared.yml`: checkout `ref=<tag>`, render `.env`, recreate, healthcheck. The ONLY net-new behavior is bd-pulse's opt-in destructive DB-snapshot restore.

### copy-prod-db (prod → dev, one-way)
| Repo | DB | Mechanism | Backup of dev before clobber? |
|------|----|-----------|-------------------------------|
| bd-pulse | SQLite | inline: WAL-safe `.backup()` of prod → `docker cp` into dev container | **No** — dev DB overwritten with no backup |
| areteos | Postgres | `git checkout develop` then `scripts/copy-prod-db.sh` (pg_dump -Fc → drop/recreate dev → pg_restore) | **No** — `DROP DATABASE dev` |
| arilearn-phx | Postgres | identical to areteos, different container/db names | **No** |
| ms-365 | — | **does not exist** (stateless) | — |

Key observations:
- copy-db checks out `develop` first specifically to run the **repo-local** `scripts/copy-prod-db.sh`. The script encodes app-specific container/db names and the dump/restore sequence. That logic is NOT in the workflow today.
- **No repo backs up the dev DB before clobbering it.** Prod is treated read-only (WAL-safe `.backup()` / `pg_dump` against a live DB — safe). The destructive side is dev, and it is currently unprotected.
- bd-pulse copy-db loads `/tailscale` only; areteos copy-db loads `/` recursive (root) — sloppy, picks up everything.

---

## Phase 1 — Explore (wide)

- **Fold rollback into `deploy-vps-shared.yml@v2`** — rollback IS a deploy at a tag. Add a `restore-db-snapshot` input + a "find latest pre-deploy snapshot and swap it in" step gated behind it. One workflow, one tag, zero new surface.
- **`rollback-vps-shared.yml`** — separate reusable workflow, copy of deploy job + the snapshot-restore step. Keeps deploy's happy path clean.
- **`copy-prod-db-shared.yml`** — separate reusable workflow for the prod→dev copy. Genuinely different shape (two DBs, two compose files, directionality), can't sensibly fold into deploy.
- **One mega `vps-ops-shared.yml`** with an `operation: deploy|rollback|copy-db` input switch. Single file, big `if:` ladders.
- **Keep copy-db logic in repo scripts** (`scripts/copy-prod-db.sh`), shared workflow just does load→tailscale→ssh→`run the repo's script`. Matches areteos/arilearn today.
- **Port copy-db logic INTO the shared workflow** as parameterized sqlite/postgres branches (mirror the deploy `db-type` switch), kill the repo scripts.
- **A reusable `db-snapshot` composite action** (sqlite `.backup()` / pg_dump) reused by deploy pre-deploy-backup, rollback restore, and copy-db source-read. Extract the duplication.
- **Rollback restores DB by default** — rejected on sight; silent data loss.
- **copy-db with a `dry-run` input** that prints the plan (which dev DB gets dropped) without executing.
- **copy-db backs up dev before clobber** (symmetry with deploy's pre-deploy snapshot) — the missing safety net.
- **A confirmation gate** (typed input `i-understand-this-clobbers-dev`) on copy-db and on rollback's DB restore.
- **arilearn blue/green divergence** — rollback's recreate step isn't always `compose up`. Needs a `recreate-command` / `redeploy-script` escape hatch, or fold blue/green into deploy first.
- **GH environment gates** — rollback→`production`, copy-db→`production` (for OIDC subject), but copy-db WRITES to dev. The environment name is about OIDC claims, not target. Worth a doc note so nobody thinks `environment: production` protects dev.

---

## Phase 2 — Converge

### Option 1: Fold rollback into deploy; new `copy-prod-db-shared.yml`

**What**: Add `restore-db-snapshot` (+ guard) to `deploy-vps-shared.yml@v2` so rollback is just `deploy(ref=<tag>)`. Build one new reusable workflow for copy-db.

**How it works**: Rollback shims call `deploy-vps-shared.yml@v2` with `ref: <tag>` and optionally `restore-db-snapshot: true`. Deploy gains a post-checkout/pre-`compose up` step (mirrors the existing pre-deploy-backup step) that, when enabled, finds the latest `pre-deploy-*` snapshot, moves the live DB aside, swaps the snapshot in, integrity-checks, then proceeds. copy-db is its own workflow with `db-type` sqlite/postgres branches, a mandatory dev-backup step, and a typed confirmation input.

**Pros**:
- Rollback inherits everything deploy already hardened: bare-KEY render, required-keys gate, no `--remove-orphans`, force-recreate, base64-over-ssh, snapshot retention. Zero re-implementation.
- The pre-deploy snapshot and the rollback restore live in the same file — the producer and consumer of `pre-deploy-snapshots/` stay coupled and can't drift.
- Smallest new surface: one new workflow, not two.

**Cons / Risks**:
- Deploy workflow grows a destructive code path. The `restore-db-snapshot` step must be inert unless explicitly true AND a snapshot exists — a bug here corrupts prod during a routine deploy.
- arilearn's blue/green redeploy doesn't fit deploy's `compose up`. Either deploy gains a `recreate-strategy` input or arilearn rollback stays bespoke. Folding rollback forces the blue/green question now.
- Conceptual overload: "deploy" doing a DB restore is surprising to a reader scanning shim names.

**Best if**: We want minimum new YAML and accept teaching `deploy-vps-shared` one guarded destructive trick — AND we solve (or defer) blue/green for arilearn.

---

### Option 2: Two new siblings — `rollback-vps-shared.yml` + `copy-prod-db-shared.yml`

**What**: A dedicated rollback workflow and a dedicated copy-db workflow, both composing the same load→tailscale→ssh actions as deploy.

**How it works**: `rollback-vps-shared.yml` is structurally a deploy job (it can even share most input names) plus the opt-in snapshot-restore step. `copy-prod-db-shared.yml` does load→tailscale→ssh with `db-type` branches: read-only snapshot of prod, mandatory backup of dev, restore into dev, healthcheck. Both keep deploy untouched.

**Pros**:
- Deploy's happy path stays clean; no destructive branch bolted onto routine deploys.
- Each workflow's name matches its intent and danger level. A reader sees `rollback-vps-shared` and knows data may move.
- arilearn's blue/green can be handled in rollback via a `redeploy-script` input without polluting deploy.
- copy-db is unavoidably its own workflow anyway (Option 1 builds it too) — this just adds one more sibling for rollback.

**Cons / Risks**:
- rollback duplicates ~90% of deploy's job body. The two will drift unless the shared steps are extracted into composite actions (see Option 3). Copy-paste of the base64/ssh/render logic is real maintenance debt.
- Three near-identical VPS workflows (deploy, rollback, copy-db) to keep in sync on every VPS-pattern change (e.g. a new ssh-action gotcha).

**Best if**: We value clear separation of dangerous ops over DRY, and are willing to either accept the duplication or follow up with composite extraction.

---

### Option 3: Option 2 + extract shared composite actions first

**What**: Before/while building the siblings, factor the repeated VPS primitives into composite actions — `render-env-to-vps` (load + merge + assert + base64 + write), `db-snapshot` (sqlite/pg, used for backup AND prod-read), `db-restore` (snapshot-swap / pg drop-restore) — then deploy, rollback, and copy-db all compose them.

**How it works**: deploy-vps-shared, rollback-vps-shared, copy-prod-db-shared each shrink to orchestration that wires composites together. The dangerous DB logic lives in one tested place; copy-db's dev-backup and rollback's restore are the same `db-restore`/`db-snapshot` action with different args.

**Pros**:
- Real DRY: one implementation of the sqlite `.backup()` / pg_dump dance, used by all three. Fixes the "no dev backup before clobber" gap once, everywhere.
- New VPS workflows become cheap to add later.
- Each workflow file is readable orchestration, not 600 lines of inline bash.

**Cons / Risks**:
- Biggest up-front effort. Requires refactoring the just-shipped, just-proven `deploy-vps-shared.yml@v2` — risk of regressing a workflow that currently works.
- Composite actions add an indirection layer and another versioned surface (`@v1` for each) to manage.
- Over-engineering risk: only 4 repos, ~3 of which deploy. The abstraction may cost more than the duplication it removes.

**Best if**: We expect more VPS services / more ops verbs soon, and the deploy workflow's inline bash is already feeling unmaintainable. Otherwise premature.

---

## The two danger questions (must be answered regardless of option)

**Rollback DB restore (destructive):**
- Default OFF. Restore only when `restore-db-snapshot: true` AND a `pre-deploy-*` snapshot exists; otherwise hard-fail rather than silently rolling back code-only-but-claiming-DB-rollback.
- Preserve bd-pulse's proven safety: stop the app container first, move the live DB aside as `.before-rollback-<ts>` (forensics + manual re-restore), clean WAL/SHM sidecars, integrity-check the restored DB before boot.
- Only bd-pulse uses this today. Make it a generic input but keep it sqlite/postgres aware via the existing `db-type` switch.

**copy-prod-db (prod read-only → dev clobber):**
- Prod is the SOURCE and must stay read-only: WAL-safe `.backup()` (sqlite) / `pg_dump` (postgres) only — never write to a prod container/db. Hard-code direction; no "swap source/target" input that could be inverted.
- **Add the missing safety net**: back up the dev DB before clobbering (snapshot file aside for sqlite; `pg_dump` of dev before `DROP DATABASE` for postgres). No repo does this today.
- Guard with a typed confirmation input and document that `environment: production` is for OIDC claims, NOT a signal that prod is the target — the write target is DEV.
- Decide: keep `scripts/copy-prod-db.sh` in repos (workflow runs it) vs. port into the workflow. Porting kills per-repo script drift and lets the dev-backup safety net be enforced centrally; keeping scripts is less churn now but leaves the gap per-repo.

---

## Phase 3 — Recommendation

**Recommended: Option 2 — two new siblings (`rollback-vps-shared.yml` + `copy-prod-db-shared.yml`), with the shared DB logic ported INTO copy-db (not left in repo scripts), and composite extraction (Option 3) explicitly deferred as a fast-follow.**

Why:
- **copy-db must be its own workflow under every option** — its shape (two DBs, two compose files, one-way clobber, mandatory dev-backup) does not fit deploy. So the only real decision is rollback: fold (Opt 1) vs. sibling (Opt 2).
- **Sibling rollback wins on safety legibility.** Bolting a destructive DB-restore branch onto the routine-deploy workflow (Opt 1) means every normal deploy carries a path that can corrupt prod. A separate `rollback-vps-shared` keeps the dangerous verb named and isolated, and gives arilearn's blue/green redeploy a natural home (a `redeploy-script` input) without forcing the blue/green question into deploy right now.
- **Accept the duplication, plan to remove it.** Opt 2's real cost is rollback duplicating deploy's job body. That's acceptable short-term and the right trigger for Option 3's composite extraction — but doing the refactor (Opt 3) up front means re-cutting the just-proven `deploy-vps-shared@v2`, which is unnecessary risk for 3-4 repos.
- **Port copy-db logic into the workflow** so the dev-backup safety net (currently missing everywhere) is enforced centrally and `scripts/copy-prod-db.sh` drift dies.

**This depends on one thing**: whether arilearn's blue/green redeploy must be covered in v1 of shared rollback. If yes → rollback needs a `recreate-strategy: compose-up | redeploy-script` input from day one (and arilearn keeps its `scripts/blue_green_deploy.sh`). If arilearn can stay on its bespoke rollback for now, ship rollback for the `compose up` repos (bd-pulse, areteos, ms-365) first and add the blue/green escape hatch as a fast-follow.

Secondary dependency: if you'd rather minimize new YAML over isolating danger, flip to **Option 1** — it's the next-best and materially smaller, at the cost of a destructive branch inside deploy.

---

## Open questions for /plan

1. arilearn blue/green: cover in rollback v1 (`recreate-strategy` input) or defer?
2. copy-db: port `scripts/copy-prod-db.sh` into the workflow (recommended) or have the workflow invoke the repo script?
3. Confirmation gate style on destructive ops: typed-string input vs. a second GH environment with required reviewers?
4. Do rollback and copy-db share a major version line with deploy (`@v2`) or get their own tags?
5. bd-pulse copy-db loads `/tailscale`; areteos/ms-365 copy-db load `/` root recursive — standardize on `/tailscale` env-mode (the deploy v2 convention) during migration.
