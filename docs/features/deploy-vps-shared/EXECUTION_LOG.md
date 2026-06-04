# Execution Log: Shared VPS Deploy Tooling v2

## [2026-06-03 00:00] — Phase 1: Action v2 dotenv render mode

- **Action**: Added `export-as-env: dotenv` mode and `dotenv-output-path` input to `action.yml`. Added `dotenv-file-path` output.
- **Guard fix applied**: Tightened existing file/JSON step guards from `inputs.export-as-env != 'true'` to `inputs.export-as-env == 'false'`. This was the structural risk identified in the pre-impl audit — without this fix, a `dotenv` value would have also satisfied `!= 'true'` and incorrectly triggered the file-fetch + JSON-conversion steps.
- **New steps added**:
  - `Fetch secrets (file mode — dotenv output path)`: uses `export-type: file` with a separate temp file path (`load-infisical-secrets-dotenv.env`) to avoid colliding with the JSON mode's temp file.
  - `Render bare dotenv file` (id: `dotenv`): pure bash — reads upstream file, strips double-quote wrapping, masks each value with `::add-mask::`, emits bare `KEY=value` lines, validates non-empty output, writes `dotenv-file-path` to `GITHUB_OUTPUT`.
- **Files changed**: `actions/load-infisical-secrets/action.yml`
- **Decisions**:
  - Used bash string pattern matching (`"${v:1:${#v}-2}"`) rather than jq for the quote-stripping step — avoids a second jq parse pass and keeps the render step dependency-free beyond bash.
  - Non-empty file validation (`[[ ! -s "$OUT_FILE" ]]`) provides an early fail before scp ships a zero-byte file to the VPS.
  - `include-imports` is an existing input that callers pass — no special handling needed in the dotenv step; it is passed through to the upstream Infisical action which resolves imports before writing the file.
- **Result**: success

## [2026-06-03 00:00] — Phase 2: Reusable deploy workflow

- **Action**: Created `.github/workflows/deploy-vps-shared.yml` as a `workflow_call` reusable workflow.
- **Files changed**: `.github/workflows/deploy-vps-shared.yml` (new)
- **Decisions**:
  - `REQUIRED CALLER PERMISSIONS` header copied verbatim-style from `release-shared.yml` (lines 19-30 pattern), adapted for `id-token: write` + `contents: read`.
  - `appleboy/scp-action@v0.1.7` pinned to a non-moving tag. `strip_components: 999` strips the runner-temp path prefix so the file lands flat at the target path.
  - `appleboy/ssh-action@v1.2.0` used for git checkout and docker compose steps. Each SSH step passes env vars explicitly via `envs:` — no shell interpolation of secrets into the script string.
  - `allow-clone` gate implemented in the repo-checkout SSH step: if `repo-dir/.git` does not exist and `allow-clone` is false, the step fails with a clear error message before touching anything on the VPS.
  - VERSION append uses `${REF#v}` to strip leading `v` from tags (e.g. `v1.2.3` → `1.2.3`). The value is masked.
  - `wait-for-healthy.sh` is fetched from the same `GH_ACTIONS_REF` as the deployed ref — version-locked, not always `v1`. This avoids the script version drifting from the action version.
  - `docker compose pull` runs before `up -d` so images are refreshed before the old containers stop — minimises downtime window.
  - `infra-path` defaults to `/tailscale` matching all existing consumer repos; no migration needed for this folder.
- **Result**: success

## [2026-06-03 00:00] — Phase 3: Docs

- **Action**: Updated action README, root README, and created migration runbook.
- **Files changed**:
  - `actions/load-infisical-secrets/README.md` — added dotenv mode usage example, updated inputs table (new `export-as-env: dotenv` value + `dotenv-output-path` input), updated outputs table (new `dotenv-file-path` output), extended Limitations section (multi-line + quotes-literal note).
  - `README.md` — updated action status (`v2`, `@v1` frozen note), added `deploy-vps-shared.yml` row to reusable workflows table, added v1-frozen callout block, removed stale "More to come — Tailscale connect" note (tailscale-connect already exists).
  - `docs/runbooks/deploy-vps-migration.md` (new) — two-sided migration runbook: Side 1 (Infisical restructure), Side 2 (dry-export verification), Side 3 (shim flip per env). Includes multi-line secret audit step, bare KEY=value verification, VPS spot-check commands, rollback instructions, and a final checklist. Notes the `/tailscale` folder naming quirk explicitly.
- **Result**: success

## Summary — Phases 1-3 complete

All Phase 1, 2, 3 steps ticked off. Stopping before Phase 4 (v2 release tag) per execution scope.

Next step when ready: Phase 4 — cut v2 per RELEASING.md (major bump), confirm `@v1` moving tag stays frozen.

## [2026-06-03] — Post-execution review (team lead) + fixes

Reviewed the generated `deploy-vps-shared.yml` against the source workflows and
the appleboy/scp-action docs. Action.yml dotenv mode passed review unchanged.
Found and fixed five defects in the reusable workflow (none pushed/released):

- **A (breaking)**: nested `load-infisical-secrets@v1` → `@v2`. The `dotenv` mode
  and the `== 'false'` guards only exist at v2; at v1 the call would hit the old
  JSON branch and `dotenv-file-path` would be empty. Both call-sites corrected.
- **C (breaking)**: scp `target` was `repo-dir/<env-file-name>` (a file path), but
  scp-action's `target` MUST be a directory — it would create a dir `.env/` and
  drop the file inside. Fixed: render to `runner.temp/<env-file-name>` so the
  basename is the desired filename, `target: repo-dir/` (dir), keep
  `strip_components: 999`. Added a **Verify env file landed** ssh step that
  asserts `repo-dir/<env-file-name>` exists and is non-empty (turns the
  undocumented strip-count edge case into a loud, debuggable failure) and
  restores `chmod 600` (present in the original areteos heredoc, dropped by the
  generated version).
- **D (regression)**: generated workflow used `pull` + `up -d` (no `--build`);
  all current consumers build from source on the VPS (`up -d --build`). Added a
  `compose-build` input (default `true`) → `up -d --build --remove-orphans`;
  `false` → `pull` then `up -d`.
- **B (harmful)**: `::add-mask::$VERSION` redacts the literal version string from
  logs (e.g. masking the word "main"). VERSION is not a secret — removed.
- **E (minor)**: reordered so checkout runs before scp (dev first-clone needs the
  dir to exist); hardened git checkout (`--force`, fast-forward only on a branch,
  no meaningless pull on a detached tag).

Validation: both files parse; `actionlint` clean on the workflow. Step order now
checkout → scp → verify → compose up → wait-for-healthy.

Scope note: Phases 1–3 complete and left in the working tree (uncommitted) for
review. Phase 4 (v2 release) and Phase 5 (areteos migration) NOT started —
gated on explicit approval. The scp/strip_components landing is the #1 thing to
confirm in the Phase 5 dev dry-run.
