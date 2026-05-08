# Cross-repo workflow consolidation analysis

Survey of `.github/workflows/` files across the six Areté repos that consume the shared-actions repo today. Goal: identify what can move from per-repo duplication into either a reusable workflow or a composite action in `aretecp/github-actions`.

Date of analysis: 2026-05-08.

## Repos surveyed

| Repo | Status | Workflows |
|---|---|---|
| `aretecp/areteos` | active | 9 |
| `aretecp/arilearn-phx` | active | 8 |
| `aretecp/bd-tracker` | active | 7 |
| `aretecp/contact-intelligence` | active (divergent stack) | 7 |
| `aretecp/arete-terraform-infrastructure` | no workflows | — |
| `aretecp/microsoft-entra-terraform-infrastructure` | no workflows | — |

The two Terraform repos have no GitHub Actions workflows at all — out of scope for this analysis. Adding CI for them is a separate question.

## Workflow inventory + duplication signal

SHA1 fingerprints by file (identical = byte-for-byte same).

| Workflow | areteos | arilearn-phx | bd-tracker | contact-intelligence | Verdict |
|---|---|---|---|---|---|
| `claude-issues.yml` | `49118a93` | `94160dc4` | `49118a93` | `49118a93` | **3 of 4 IDENTICAL** — 1-line drift on arilearn-phx |
| `release.yml` | `c1c46d5c` | `c1c46d5c` | `27e2a1c2` | n/a | **2 of 3 IDENTICAL** — bd-tracker has comment-only drift |
| `pr-to-main-hooks.yml` | `8c83f1ac` | `8c83f1ac` | `4f41079e` | n/a | **2 of 3 IDENTICAL** — bd-tracker added `environment:` scope |
| `rollback-prod.yml` | divergent | divergent | divergent | n/a | All differ — line counts 96/101/72 |
| `copy-prod-db.yml` | divergent | divergent | divergent | n/a | All differ — small files (50-ish lines), pattern is similar |
| `deploy-dev.yml` | divergent | divergent | divergent | divergent | All differ — expected, repo-specific |
| `deploy-prod.yml` | divergent | divergent | divergent | divergent | All differ — expected, repo-specific |
| `ci.yml` | divergent | divergent | n/a | divergent | All differ — language/stack-specific (Elixir vs Python vs Phoenix) |
| `publish-python-sdk.yml` | unique | n/a | n/a | n/a | One-of-a-kind, leave alone |
| `copy-data.yml`, `pr-close-issues.yml`, `seed-graph.yml` | n/a | n/a | n/a | unique | contact-intelligence-specific |

## Detailed divergence

### `claude-issues.yml` — strong reusable-workflow candidate
3 of 4 repos byte-identical. arilearn-phx is missing a single line: `environment: production`.

```diff
- environment: production
```

**Recommendation:** extract as reusable workflow. Make `environment` a passthrough input (default `production`). Each consumer's repo gets a 6-line shim:

```yaml
# .github/workflows/claude-issues.yml in any consumer repo
on: { issues: { types: [opened] }, issue_comment: { types: [created] } }
jobs:
  triage:
    uses: aretecp/github-actions/.github/workflows/claude-issue-triage.yml@v1
    with:
      environment: production
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

**Effort:** ~30 minutes. **Wins:** single source of truth across 4 repos.

### `release.yml` — strong reusable-workflow candidate
2 of 3 repos identical. bd-tracker drift is comment-only (rewording the docstrings about how semantic-release reads commits) plus one example example string diff (`1.x.x → 2.0.0` vs `2.x.x → 3.0.0`). Logic is identical.

**Recommendation:** extract as reusable workflow. No parameters needed; the bd-tracker example-string difference is purely cosmetic and can adopt one canonical wording.

**Effort:** ~30 minutes.

### `pr-to-main-hooks.yml` — strong candidate, biggest payoff
2 of 3 repos identical (areteos, arilearn-phx). bd-tracker added `environment: production` and a comment block explaining why — this addition is the **correct** version. Without env scope, the env-level `ANTHROPIC_API_KEY` and `TEAMS_PR_NOTIFY_WEBHOOK_URL` secrets resolve to empty (same env-scoping behavior we documented in the load-infisical-secrets pilot).

**areteos and arilearn-phx are subtly broken on this** — when their pr-to-main-hooks.yml fires, the env-scoped secrets are empty and the Claude summary + Teams notification silently no-op. bd-tracker's version actually works.

**Recommendation:** adopt bd-tracker's version as the canonical reusable workflow. This is also a **bug fix** for two repos.

**Effort:** ~1-2 hours (300+ line file, careful extraction).

### `rollback-prod.yml` — composite action candidates, not reusable workflow
All three repos differ. Line counts are 96 / 101 / 72 — meaningful divergence, likely tied to per-app docker-compose service names, container names, env file paths, etc.

The structure is shared (Tailscale → SSH → docker compose down → docker compose up @ tag → wait healthy), but the inner shell varies enough that a single reusable workflow would need many parameters.

**Recommendation:** keep workflow files per repo. Extract the shared *steps* as composite actions:
- `tailscale-connect` — used here + 4-8 other workflows per repo
- `wait-for-healthy-containers` — pattern used in deploy-dev/deploy-prod/rollback-prod (~10 places)

### `copy-prod-db.yml` — small, low-priority
All three differ. Line counts 58 / 55 / 48. Same general flow (Tailscale → SSH → pg_dump on prod → pg_restore on dev). Differences are likely service name / DB name / container name strings.

**Recommendation:** leave per-repo for now. Same composite-action benefit applies (`tailscale-connect`) but pulling out is low-priority.

### `deploy-dev.yml` / `deploy-prod.yml` — repo-specific, but composite actions help
All four (or three) repos differ. Each has app-specific env vars, service names, deploy targets. Already partially consolidated via `load-infisical-secrets`.

**Recommendation:** stay per-repo at the workflow level. Future shared composite actions (`tailscale-connect`, `wait-for-healthy-containers`) apply here.

### `ci.yml` — leave alone
Language/stack-specific. Elixir/Phoenix builds differ from Python/uv builds differ from JS/TS builds. The repos that share a stack might warrant a reusable workflow eventually (`elixir-ci`, `python-ci`), but with only 2-3 repos per stack, the abstraction cost outweighs the benefit. Revisit when 4+ repos share a stack.

## Consolidation roadmap

Ordered by **value-per-effort**:

### Tier 1 — Quick wins, ship in one PR each

1. **`claude-issue-triage` reusable workflow** — extract from the canonical `49118a93` version. Update 4 consumer shims. Fixes the arilearn-phx env-scoping drift for free.
2. **`release` reusable workflow** — extract from `c1c46d5c`. Update 3 consumer shims. Closes the bd-tracker comment drift.
3. **`pr-to-main-hooks` reusable workflow** — extract from bd-tracker's version (the env-scoped one). Update areteos + arilearn-phx shims. **This is also a bug fix** — areteos and arilearn-phx are silently failing on env-scoped secrets in their current versions.

### Tier 2 — Composite actions for deploy-pattern reuse

4. **`actions/tailscale-connect`** — wraps `tailscale/github-action@v3` with org defaults. Used in 8+ workflows per repo, 4 repos = 30+ usages. Saves a few lines but standardizes the version pin and auth method for future Tailscale upgrades.
5. **`actions/wait-for-healthy-containers`** — encapsulates the `for i in $(seq 1 30); ... docker inspect ... healthy` pattern from deploy-dev, deploy-prod, rollback-prod (10+ usages).

### Tier 3 — Defer

6. `copy-prod-db.yml` workflow consolidation — too repo-specific for the payoff.
7. `ci.yml` consolidation — wait until 4+ repos share a stack.
8. Terraform repo CI/CD — separate scope; orthogonal to this analysis.

## Anti-patterns observed

A few notes worth capturing for when we do the consolidation work:

- **Env-scoping bug**: 2 of 3 repos' `pr-to-main-hooks.yml` are missing `environment: production` and silently fail on env-scoped secrets. Same trap we hit in the load-infisical-secrets pilot. Worth a CONTRIBUTING.md note in this repo: any workflow consuming env-level GH secrets MUST declare `environment:` on the job, otherwise `${{ secrets.X }}` resolves to empty in private repos on GitHub Free.
- **Comment drift**: release.yml's bd-tracker variant differs only in inline comment wording. Strong signal that the file was force-updated independently in each repo at different times. A reusable workflow eliminates this drift category entirely.
- **`environment: production` placement**: claude-issues had it in 3 repos, missing in arilearn-phx. Same drift pattern. Always-have-it convention saves time.

## Next steps

If/when the team wants to act on this, suggested order:

1. File a tracking issue here — link this doc; enumerate the 5 consolidation tasks (3 reusable workflows + 2 composite actions)
2. Tier 1 PRs in this order: `release` (smallest, lowest risk) → `claude-issue-triage` → `pr-to-main-hooks` (biggest, also bug fix)
3. After Tier 1: extract `tailscale-connect` composite, then `wait-for-healthy-containers`
4. Document reusable-workflow vs composite-action conventions in CONTRIBUTING.md
