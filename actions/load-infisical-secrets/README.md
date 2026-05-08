# `load-infisical-secrets`

Composite action that fetches secrets from Areté's Infisical instance via Universal Auth and exports them to subsequent workflow steps.

Wraps [`Infisical/secrets-action`](https://github.com/Infisical/secrets-action), pinned to a specific commit SHA. Adds Areté-specific defaults (self-hosted instance URL, sensible env-export behavior) and an optional JSON output mode.

## Usage

### Default — export as env vars

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    project-slug: arete-platform
    environment: prod
    client-id: ${{ secrets.INFISICAL_CLIENT_ID }}
    client-secret: ${{ secrets.INFISICAL_CLIENT_SECRET }}

- name: Use the secrets
  run: |
    echo "Database is up at: $DATABASE_URL"
    # ... DATABASE_URL, STRIPE_KEY, etc. are all in env now
```

### JSON output mode (no env pollution)

```yaml
- id: load
  uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    project-slug: arete-platform
    environment: prod
    export-as-env: 'false'
    client-id: ${{ secrets.INFISICAL_CLIENT_ID }}
    client-secret: ${{ secrets.INFISICAL_CLIENT_SECRET }}

- name: Pass one secret to a downstream action
  uses: some/other-action@v1
  with:
    api-key: ${{ fromJSON(steps.load.outputs.secrets).STRIPE_KEY }}
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `project-slug` | yes | — | Infisical project slug (e.g. `arete-platform`). **Not** the project UUID. |
| `environment` | yes | — | Infisical env slug (`prod`, `staging`, `dev`, ...) |
| `path` | no | `/` | Folder path within the project |
| `client-id` | yes | — | Universal Auth client ID. Pass `${{ secrets.INFISICAL_CLIENT_ID }}` from the org-level secret |
| `client-secret` | yes | — | Universal Auth client secret. Pass `${{ secrets.INFISICAL_CLIENT_SECRET }}` from the org-level secret |
| `export-as-env` | no | `'true'` | `'true'` writes secrets to `$GITHUB_ENV` for subsequent steps. `'false'` skips env and emits the JSON `secrets` output instead |
| `recursive` | no | `'false'` | `'true'` fetches secrets at the given path AND all subpaths |
| `include-imports` | no | `'true'` | `'true'` follows Infisical env-import links (e.g. `prod` env importing from a `shared` project) |
| `domain` | no | `https://secrets.areteintelligence.ai/` | Infisical instance URL. Override to target Infisical Cloud (`https://app.infisical.com`) or another instance |

## Outputs

| Output | Description |
|---|---|
| `secrets` | JSON map `{ "NAME": "value", ... }` of resolved secrets. Set **only** when `export-as-env: 'false'`. Each value is masked via `::add-mask::` before the output is set. Parse with `${{ fromJSON(steps.<id>.outputs.secrets).KEY }}` |

## Auth setup

This action uses **Universal Auth** against a shared `gh-actions-shared` machine identity in Infisical. Credentials live as `aretecp` org-level GitHub Actions secrets (`INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`) and are scoped to selected repos.

For machine identity scope, secret rotation, and onboarding new repos: see [`docs/runbooks/infisical-machine-identity.md`](../../docs/runbooks/infisical-machine-identity.md).

## Limitations

- **Multi-line secret values** (PEM keys, certificates with newlines, etc.) are **not supported** when `export-as-env: 'false'`. The `.env`-to-JSON parser is single-line. Use env mode for multi-line values, or open an issue if JSON output for multi-line is needed.
- **`ubuntu-latest` runners only** — relies on `jq` and `bash` being preinstalled. macOS and Windows runners are untested; file an issue if you need them.

## Bumping the upstream `Infisical/secrets-action` SHA

This action is pinned to a specific commit SHA of `Infisical/secrets-action` (not a moving tag). To bump:

1. Find the latest stable tag and its commit SHA:
   ```bash
   gh api /repos/Infisical/secrets-action/tags --jq '.[0:5] | .[] | {name, sha: .commit.sha}'
   ```
2. Read the upstream changelog/release notes for breaking changes:
   ```bash
   gh release list --repo Infisical/secrets-action
   gh release view <tag> --repo Infisical/secrets-action
   ```
3. Update both `uses:` lines in this action's `action.yml` to the new SHA. Update the `# vX.Y.Z` trailing comment.
4. If the upstream change introduces, removes, or renames any input/output that we expose: bump **major** version of `load-infisical-secrets` per [`CONTRIBUTING.md`](../../CONTRIBUTING.md). Otherwise minor or patch as appropriate.
5. Open a PR. The smoke test (issue #4 once landed) will exercise the new SHA against a real Infisical project.

## Versioning policy

See [`CONTRIBUTING.md`](../../CONTRIBUTING.md#versioning) for the full policy. Quick summary for this action:

| Change | Bump |
|---|---|
| Internal refactor, no caller-visible change | patch |
| New optional input or behavior, default unchanged | minor |
| Renamed/removed input or output, changed default, breaking shape change | **major** (and update the moving `v1` tag policy) |
| Upstream SHA bump with no caller-visible change | patch |
| Upstream SHA bump that surfaces new behavior to callers | minor or major depending on visibility |
