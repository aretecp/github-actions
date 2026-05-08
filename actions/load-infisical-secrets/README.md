# `load-infisical-secrets`

Composite action that fetches secrets from Areté's Infisical instance via Universal Auth and exports them to subsequent workflow steps.

Wraps [`Infisical/secrets-action`](https://github.com/Infisical/secrets-action), pinned to a specific commit SHA. Adds Areté-specific defaults (self-hosted instance URL) and an optional JSON output mode.

## Prerequisites

The consumer repo's workflow needs to be able to read the following `aretecp` org-level configuration. **All of these are managed at the org level — set once, reused everywhere.**

### Required org-level **Actions secrets**

Already set in the `aretecp` org with visibility `All repositories` (every repo in the org can read them):

| Secret | What it is |
|---|---|
| `INFISICAL_CLIENT_ID` | Universal Auth client ID for the shared GitHub Actions machine identity |
| `INFISICAL_CLIENT_SECRET` | Universal Auth client secret for the same identity |

If you ever tighten visibility to `Selected`, make sure the consumer repo is included or the action will fail at authentication time.

### Recommended org-level **Actions variables** (not secrets)

Project slugs are stable, public identifiers — store as variables, not secrets, for one source of truth.

| Variable | Value | Use in workflows |
|---|---|---|
| `INFISICAL_INTERNAL_PROJECT_SLUG` | `arete-internal` | `${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}` |
| `INFISICAL_EXTERNAL_PROJECT_SLUG` | `arete-external` | `${{ vars.INFISICAL_EXTERNAL_PROJECT_SLUG }}` |
| `INFISICAL_SHARED_PROJECT_SLUG` | `arete-shared` | `${{ vars.INFISICAL_SHARED_PROJECT_SLUG }}` |

Workflows can also pass the slug as a literal (`project-slug: arete-internal`) — variables are an ergonomic convention, not a requirement.

### Already set in `aretecp` org

The following secrets exist in the org but **are not consumed by this action** (this action needs the *slug*, not the UUID). They're useful for direct Infisical API calls or other tooling:

- `INFISICAL_INTERNAL_PROJECT_ID`
- `INFISICAL_EXTERNAL_PROJECT_ID`
- `INFISICAL_SHARED_PROJECT_ID`
- `INFISICAL_ORG_ID`

### Identity scope and rotation

Machine identity setup, scope, and the rotation procedure live in [`docs/runbooks/infisical-machine-identity.md`](../../docs/runbooks/infisical-machine-identity.md).

## Usage

### Default — export as env vars

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
    environment: prod
    client-id: ${{ secrets.INFISICAL_CLIENT_ID }}
    client-secret: ${{ secrets.INFISICAL_CLIENT_SECRET }}

- name: Use the secrets
  run: |
    echo "Database is up at: $DATABASE_URL"
    # ... DATABASE_URL, STRIPE_KEY, etc. are all in env now
```

### Pulling from a different project

Replace the slug variable. Common patterns:

```yaml
# External-facing project
project-slug: ${{ vars.INFISICAL_EXTERNAL_PROJECT_SLUG }}

# Shared org-wide project
project-slug: ${{ vars.INFISICAL_SHARED_PROJECT_SLUG }}

# Or literal, no variable indirection
project-slug: arete-internal
```

### JSON output mode (no env pollution)

```yaml
- id: load
  uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
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
| `project-slug` | yes | — | Infisical project slug (e.g. `arete-internal`). **Not** the project UUID. |
| `environment` | yes | — | Infisical env slug (`prod`, `staging`, `dev`, ...) |
| `path` | no | `/` | Folder path within the project |
| `client-id` | yes | — | Universal Auth client ID. Pass `${{ secrets.INFISICAL_CLIENT_ID }}` |
| `client-secret` | yes | — | Universal Auth client secret. Pass `${{ secrets.INFISICAL_CLIENT_SECRET }}` |
| `export-as-env` | no | `'true'` | `'true'` writes secrets to `$GITHUB_ENV` for subsequent steps. `'false'` skips env and emits the JSON `secrets` output instead |
| `recursive` | no | `'false'` | `'true'` fetches secrets at the given path AND all subpaths |
| `include-imports` | no | `'true'` | `'true'` follows Infisical env-import links (e.g. `prod` env importing from a `shared` project) |
| `domain` | no | `https://secrets.areteintelligence.ai` | Infisical instance URL. Override to target Infisical Cloud (`https://app.infisical.com`) or another instance |

## Outputs

| Output | Description |
|---|---|
| `secrets` | JSON map `{ "NAME": "value", ... }` of resolved secrets. Set **only** when `export-as-env: 'false'`. Each value is masked via `::add-mask::` before the output is set. Parse with `${{ fromJSON(steps.<id>.outputs.secrets).KEY }}` |

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
