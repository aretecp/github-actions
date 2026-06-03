# Plan: Shared VPS Deploy Tooling v2

**Status**: In Progress
**Created**: 2026-06-03
**Last updated**: 2026-06-03

## Summary
Service repos deploy to a Tailscale-reachable VPS via near-identical GitHub Actions jobs whose runtime `.env` is hand-maintained as a heredoc listing each variable explicitly. Adding a secret in Infisical does not reach the VPS until someone edits the workflow. v2 makes the app's Infisical folder the single source of truth: the shared action renders the whole folder to a dotenv file, a new reusable workflow ships it to the VPS via scp, and per-repo deploy workflows collapse to ~15-line shims. Success: add/rename a secret in Infisical → it lands in the deployed `.env` on next deploy, no workflow edit.

## Approach
Clean **v2 major** for the action `actions/load-infisical-secrets` and a new reusable workflow `.github/workflows/deploy-vps-shared.yml`. `@v1` stays frozen so current consumers are unaffected; migration is opt-in, one repo at a time, areteos first (matches the major-bump policy in CONTRIBUTING.md referenced in the action headers).

Mechanism:
- **Enhance the shared action** with an additive dotenv-output mode (e.g. `dotenv-output-path` input / `export-as-env: dotenv`) that emits a complete dotenv file for an Infisical folder. No `infisical export` CLI — it is a second auth path and a second tool to pin (rejected).
- The reusable workflow consumes that file and ships it to the VPS with **scp** (`appleboy/scp-action`) rather than interpolating a multi-line blob into the SSH script string (avoids quoting issues).
- **Non-secret config moves into Infisical** so the folder export is the complete `.env`: PHX_HOST/PHX_HOST_DEV, EMAIL_FROM_ADDRESS, ENVIRONMENT, LANGFUSE_HOST, AUDIT_RETENTION_DAYS (and any current `vars`-sourced values) become plain non-secret values in the app folder. VERSION is deploy-computed — keep it appended at deploy time, not in Infisical.
- **Two Infisical loads only**, every repo/env:
  - **App folder** (e.g. `/areteos`) in dotenv mode → rendered `.env` → shipped to VPS. Shared deps (SES, Teams) ride along via **Infisical imports** (`include-imports: true`, already supported) inside the single app-folder render — no separate load.
  - **Infra/deploy folder** = the existing **`/tailscale`** folder in the shared project (loaded recursive, env-mode, job-only). It already yields the three infra creds — `TAILSCALE_AUTHKEY`, `VPS_TAILSCALE_IP`, `VPS_SSH_KEY` — and every consumer repo already points at it, so no Infisical data migration. Deploy-time creds — NEVER written into the app `.env`. (Name is narrower than its contents; documented in the runbook. No rename in v2 — that's cross-repo churn for cosmetics.)

OIDC means no stored creds: no `secrets:` passing between caller and reusable workflow. Caller grants `permissions: id-token: write, contents: read`.

## Reusable Workflow Inputs (refine during implementation)
| Input | Purpose |
|-------|---------|
| `environment` | dev/prod — GH environment + approval gates |
| `infisical-identity-id` | OIDC machine identity |
| `shared-project-slug` | project holding shared deps + infra folder |
| `app-project-slug` | project holding the app folder |
| `env-slug` | Infisical env (dev/prod) |
| `app-path` | app folder path (e.g. `/areteos`) → dotenv render |
| `infra-path` | infra/deploy folder path (env-mode, job-only) — default `/tailscale` |
| `vps-user` | SSH user on the VPS |
| `repo-dir` | target checkout dir on the VPS |
| `repo-url` | clone URL (used only when `allow-clone`) |
| `compose-file` | compose file to run on the VPS |
| `env-file-name` | rendered env filename — input, `.env` (prod) / `.env.dev` (dev) |
| `ref` | branch or tag to deploy |
| `allow-clone` | bool — dev `true`, prod `false`/refuse-clone |
| `healthcheck-containers` | space-separated, fed to `scripts/wait-for-healthy.sh` |

No `secrets:` block — OIDC. Caller grants `id-token: write`, `contents: read`.

## Affected Files / Components
| File / Component | Change | Why |
|-----------------|--------|-----|
| `actions/load-infisical-secrets/action.yml` | Add additive dotenv-output mode emitting bare `KEY=value`, masking preserved | Make the app folder render to a complete `.env`; no CLI export |
| `.github/workflows/deploy-vps-shared.yml` (new) | Reusable `workflow_call` deploy job (2 Infisical loads, tailscale, render, scp, compose up, healthcheck) | Collapse per-repo deploy boilerplate to a shim |
| `actions/load-infisical-secrets/README.md` | Document dotenv mode + multi-line limitation | Consumer guidance |
| `README.md` | Document v2 action mode + reusable deploy workflow + v1-frozen note | Discoverability |
| `docs/runbooks/deploy-vps-migration.md` (new) | Per-repo migration runbook (Infisical restructure → verify → flip shim → deploy) | Repeatable, ordering-safe migration |
| `aretecp/areteos` `deploy-dev.yml` / `deploy-prod.yml` | Replace heredoc jobs with ~15-line shims calling `deploy-vps-shared.yml@v2` | Reference migration |
| areteos Infisical folders | Restructure: imports, standardized infra folder, non-secret config moved in | Folder export = complete `.env` |

Existing precedent for the shim + permissions-documentation header is `.github/workflows/release-shared.yml` (see its `REQUIRED CALLER PERMISSIONS` block, lines 19-30). The action's single-line-only render limitation is documented at `actions/load-infisical-secrets/action.yml` lines 156-159.

## Implementation Steps

### Phase 1 — Action v2: dotenv render mode
- [x] Add additive dotenv-output mode to `action.yml` (new input, e.g. `dotenv-output-path` / `export-as-env: dotenv`) that writes the full Infisical folder to a file.
- [x] jq render must emit **bare `KEY=value`** — no quote-wrapping (`docker compose --env-file` does no interpolation and treats quotes literally).
- [x] Preserve masking — `::add-mask::` every value, same as existing JSON/env paths.
- [x] Confirm `include-imports: true` folds shared-dep imports into the single render.
- [x] Add a render test/validation: assert bare `KEY=value`, imports present, masking applied; assert old `@v1` modes unchanged. (inline validation: non-empty file check + guard tightening from `!= 'true'` to `== 'false'` so dotenv mode cannot trigger JSON/file steps)

### Phase 2 — Reusable deploy workflow
- [x] Create `.github/workflows/deploy-vps-shared.yml` (`workflow_call`) with the inputs above.
- [x] Add the `REQUIRED CALLER PERMISSIONS` header block (verbatim convention from `release-shared.yml`): `id-token: write`, `contents: read`.
- [x] Load #1: app folder in dotenv mode → render `.env`; append deploy-computed VERSION.
- [x] Load #2: infra/deploy folder env-mode, job-only (TAILSCALE_AUTHKEY, VPS_TAILSCALE_IP, VPS_SSH_KEY) — never written to the app `.env`.
- [x] Connect via `tailscale-connect`, scp the rendered file to `repo-dir/env-file-name` via `appleboy/scp-action`.
- [x] `allow-clone` gate: dev may clone; prod refuses-clone (require existing checkout).
- [x] Run `docker compose --env-file ... up`, then `scripts/wait-for-healthy.sh` over `healthcheck-containers`.
- [x] Scope to **deploy-from-scratch only** in v2 (not rollback-prod / copy-prod-db — see Open Questions).

### Phase 3 — Docs
- [x] Update action README (dotenv mode + multi-line limitation) and root README (v2 + v1-frozen note).
- [x] Write `docs/runbooks/deploy-vps-migration.md`: the two-sided, sequenced per-repo procedure.

### Phase 4 — Release
- [ ] Cut v2 per RELEASING.md (major bump). Confirm `@v1` moving tag stays frozen.

### Phase 5 — areteos reference migration (sequenced)
- [ ] **Restructure Infisical first**: add imports, create standardized infra folder, move non-secret config (PHX_HOST*, EMAIL_FROM_ADDRESS, ENVIRONMENT, LANGFUSE_HOST, AUDIT_RETENTION_DAYS) into the app folder. Must land BEFORE the shim flips, or the first v2 deploy comes up with a half-empty `.env`.
- [ ] Confirm areteos app folder has **no multi-line secrets** (PEM keys) — dotenv render does not support them.
- [ ] Dry-run / verify export of the app folder matches the current heredoc `.env`.
- [ ] Flip `deploy-dev.yml` to the v2 shim → deploy dev → verify running `.env` and healthchecks.
- [ ] Flip `deploy-prod.yml` to the v2 shim → deploy prod → verify.

### Phase 6 — Follow-up (fast-follow, not deferred)
- [ ] File migration issues for ms-365-mcp-server, arilearn-phx, bd-pulse (same restructure→shim sequence, each gated on a no-multi-line-secrets check).
- [ ] Extend the reusable workflow (or a sibling) to cover rollback-prod / copy-prod-db — scheduled soon after the deploy path lands, not "someday".

## Out of Scope
- rollback-prod and copy-prod-db coverage in v2 (deploy-from-scratch only first).
- Migrating ms-365-mcp-server, arilearn-phx, bd-pulse (follow-up issues; areteos is the reference).
- Touching v1 consumers, the `@v1` tag, or `claude-issues` / `pr-to-main-hooks` (load-only consumers, no deploy pattern).
- Multi-line secret support in dotenv render (existing limitation carried forward).

## Risks / Tradeoffs
- **Reusable-workflow permissions**: caller must grant `id-token: write` + `contents: read` or the call fails at startup. Mitigation: copy the `REQUIRED CALLER PERMISSIONS` header convention from `release-shared.yml` verbatim into each shim.
- **Multi-line secrets unsupported** in dotenv render (action.yml:156-159). Mitigation: per-repo pre-migration check; block migration if a PEM-style secret lives in the app folder.
- **`docker compose --env-file` does no interpolation and treats quotes literally**. Mitigation: render bare `KEY=value`, validated in Phase 1 test.
- **Two-sided migration ordering**: Infisical restructure must precede the shim flip per repo+env or the first deploy is half-empty. Mitigation: enforce ordering in the runbook; dry-export verification gate before flipping.
- **Non-secret config now in Infisical**: a single source of truth, but config drift moves out of git history into Infisical. Accepted — Infisical is already the deploy-time source of truth.

## Blast Radius / Back-Compat
All listed consumers pin `load-infisical-secrets@v1` AND `tailscale-connect@v1` on the same deploy pattern. **v1 must stay frozen**; migration is opt-in per repo.
- **areteos**: deploy-dev, deploy-prod, rollback-prod, copy-prod-db (reference migration)
- **ms-365-mcp-server**: deploy-dev, deploy-prod, rollback-prod
- **arilearn-phx**: deploy-dev, deploy-prod, rollback-prod, copy-prod-db
- **bd-pulse**: deploy-dev, deploy-prod, rollback-prod, copy-prod-db (also claude-issues, pr-to-main-hooks use load-infisical-secrets — load-only, not deploy)

`rollback-prod` and `copy-prod-db` share the load+tailscale pattern but are NOT deploy-from-scratch. Recommendation: keep v2 deploy-only first; evaluate covering the others as a follow-up.

## Resolved Decisions
- **Infra folder**: reuse existing **`/tailscale`** (already holds all three infra creds; every repo points at it; no data migration). Name kept despite being narrower than its contents — rename is cross-repo churn for cosmetics. Documented in runbook.
- **`env-file-name`**: real input — `.env` (prod) / `.env.dev` (dev).
- **Scope**: v2 is deploy-from-scratch only; rollback-prod / copy-prod-db are a **fast-follow**, scheduled soon after, not deferred indefinitely.

## Skills / Agents to Use
- **pre-impl-audit**: before the action.yml change — it is contract-touching (new output mode consumed by a new workflow and, later, every shim). Grep all v1 consumers to confirm the additive mode does not alter existing behavior.
- **compounder**: after areteos migration — capture the migration sequence and the multi-line-secret gotcha as a reusable pattern.
