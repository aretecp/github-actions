# Areté Capital Partners — Shared GitHub Actions

Reusable composite actions and workflows for `aretecp` repos. Drop-in `uses:` references with org defaults baked in — no copy-pasted workflow steps across repos.

## Available composite actions

| Action | Description | Status |
|---|---|---|
| [`load-infisical-secrets`](actions/load-infisical-secrets) | Load secrets from Infisical at workflow runtime via Universal Auth | `v1.0.1` |

More to come — Tailscale connect, Slack notify, Elixir/OTP setup, uv/Python setup. Each ships as its own composite action under `actions/<name>/`.

## Available reusable workflows

| Workflow | Description | Status |
|---|---|---|
| [`release-shared.yml`](.github/workflows/release-shared.yml) | Squash-merge → conventional-commit promotion → semantic-release → optional deploy trigger | `v1` |
| [`claude-issue-triage.yml`](.github/workflows/claude-issue-triage.yml) | Auto-triage of new issues / `@claude` comments via Claude Code. Bundled system prompt at `.claude/prompts/ci-triage.md`. | `v1` |

Reusable workflows are called via `jobs.<name>.uses: aretecp/github-actions/.github/workflows/<file>@v1` in the consumer repo. See the workflow file's header comments for inputs and prerequisites.

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

## Releasing

Cutting a new version of any action in this repo: see [`RELEASING.md`](RELEASING.md).

## License

MIT — see [`LICENSE`](LICENSE).
