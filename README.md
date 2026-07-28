# Areté Capital Partners — Shared GitHub Actions

Reusable composite actions and workflows for `aretecp` repos. Drop-in `uses:` references with org defaults baked in — no copy-pasted workflow steps across repos.

## Available composite actions

| Action | Description | Status |
|---|---|---|
| [`load-infisical-secrets`](actions/load-infisical-secrets) | Load secrets from Infisical at workflow runtime. Supports env export, JSON output, and bare dotenv file render (v2). | `v2` (`@v1` frozen) |
| [`tailscale-connect`](actions/tailscale-connect) | Join the Areté Tailscale tailnet. Wraps `tailscale/github-action` with a pinned SHA and corrected input names. | `v1` |

More to come — Slack notify, Elixir/OTP setup, uv/Python setup. Each ships as its own composite action under `actions/<name>/`.

> **`@v1` is frozen.** All existing consumers that pin `load-infisical-secrets@v1` are unaffected. The v2 `dotenv` render mode is additive — migrate one repo at a time via the [VPS deploy migration runbook](docs/runbooks/deploy-vps-migration.md).

## Available reusable workflows

| Workflow | Description | Status |
|---|---|---|
| [`release-shared.yml`](.github/workflows/release-shared.yml) | Squash-merge → conventional-commit promotion → semantic-release → optional deploy trigger | `v1` |
| [`deploy-vps-shared.yml`](.github/workflows/deploy-vps-shared.yml) | Render Infisical folder → dotenv → write to VPS over ssh → docker compose up → healthcheck. Callers become ~15-line shims. | `v2` |
| [`claude-issue-triage.yml`](.github/workflows/claude-issue-triage.yml) | Auto-triage of new issues / `@claude` comments via Claude Code. Bundled system prompt at `.claude/prompts/ci-triage.md`. Callers pass **no inputs at all** — see [zero-config shim](#zero-config-consumer-shim). | `v2` |
| [`pr-to-main-hooks.yml`](.github/workflows/pr-to-main-hooks.yml) | On PRs targeting `main`: gather context → Claude summary → update PR body + Closes #N footers → Teams card. | `v1` |

Reusable workflows are called via `jobs.<name>.uses: aretecp/github-actions/.github/workflows/<file>@v1` in the consumer repo. See the workflow file's header comments for inputs and prerequisites.

### Zero-config consumer shim

`claude-issue-triage.yml@v2` needs **no `with:` block**. It reads the caller's own
`vars.INFISICAL_OIDC_IDENTITY_ID` / `vars.INFISICAL_INTERNAL_PROJECT_SLUG` (unlike secrets, org
variables resolve against the caller), loads `ANTHROPIC_API_KEY` from the shared CI folder
`arete-internal/prod/github-actions`, and checks out the consumer's own default branch:

```yaml
name: Claude Issue Triage

on:
  issues:
    types: [opened]
  issue_comment:
    types: [created]

# Reusable workflows can only USE permissions the caller grants.
permissions:
  contents: read
  issues: write
  id-token: write

jobs:
  triage:
    uses: aretecp/github-actions/.github/workflows/claude-issue-triage.yml@v2
```

That is the entire file. Every `infisical-*` input, plus `checkout-ref`, `environment`, and
`claude-model`, remain available as optional overrides — pass `checkout-ref` only if you want to
triage against something other than your default branch.

> The CI key in `/github-actions` is deliberately separate from each app's own
> `ANTHROPIC_API_KEY`. Apps keep theirs for runtime use; CI has its own so spend is attributable
> and revocation is isolated.

## Usage

Pin to the moving major tag for non-breaking updates:

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
    environment: prod
    client-id: ${{ secrets.INFISICAL_CLIENT_ID }}
    client-secret: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

> Each consuming workflow needs access to the `INFISICAL_CLIENT_ID` / `INFISICAL_CLIENT_SECRET` org secrets and the `INFISICAL_*_PROJECT_SLUG` org variables. See the action's [`README`](actions/load-infisical-secrets/README.md#prerequisites) for full prerequisites.

Or pin to a specific version / SHA for stricter reproducibility:

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1.0.0
- uses: aretecp/github-actions/actions/load-infisical-secrets@<full-commit-sha>
```

## Versioning

- `@v1` — moving major tag; tracks the latest `1.x.y`. Recommended for most consumers.
- `@v1.2.3` — exact version; pin if you need reproducibility but can tolerate manual upgrades.
- `@<sha>` — strictest. Pin if your security posture requires it.

Breaking changes bump the major. The `v1` tag stays on `1.x` forever.

## Shared scripts ([`scripts/`](scripts))

Runtime utilities consumer workflows fetch via curl + run inside their existing SSH scripts on the deploy target. The GH runner can't reach the VPS's Docker daemon, so these execute on the VPS at deploy time. See [`scripts/README.md`](scripts/README.md).

## Admin tools ([`tools/`](tools))

Maintainer scripts for org-wide GH config — secret syncing, post-migration cleanup. Run locally with `gh` CLI auth, never fetched from a workflow. See [`tools/README.md`](tools/README.md).

## Releasing

Cutting a new version of any action in this repo: see [`RELEASING.md`](RELEASING.md).

## License

MIT — see [`LICENSE`](LICENSE).
