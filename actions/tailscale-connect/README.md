# `tailscale-connect`

Composite action that joins the Areté Tailscale tailnet on a GitHub Actions runner. Wraps [`tailscale/github-action`](https://github.com/tailscale/github-action), pinned to a specific SHA. Adds Areté-specific defaults (CLI version pin) and corrects the input name (`version`, not the deprecated `tailscale-version`).

## Usage

```yaml
- uses: aretecp/github-actions/actions/tailscale-connect@v2
  with:
    authkey: ${{ secrets.TAILSCALE_AUTHKEY }}
```

After this step succeeds, subsequent steps in the same job have Tailscale connectivity to the tailnet.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `authkey` | yes | — | Tailscale auth key. Pass `${{ secrets.TAILSCALE_AUTHKEY }}` from the consumer repo |
| `version` | no | `1.80.0` | Tailscale CLI version |

## Outputs

None. Side effect: the runner is joined to the tailnet for the duration of the job.

## What this fixes vs. raw upstream usage

Three things consumers were getting wrong without this wrapper:

1. **`tailscale-version:` is the wrong input name** — upstream renamed it to `version`. Old workflows produced `Unexpected input(s) 'tailscale-version'` warnings and silently fell back to upstream's default. This action uses the correct name internally.
2. **`@v3` is a moving tag** — risks of an unannounced upstream version bump landing without code review. This action pins to a specific SHA, so upstream bumps go through a PR.
3. **Version drift across workflows** — 14+ usages × 4 repos meant ad-hoc `tailscale-version` strings. Now there's one canonical default.

## Auth migration note

Upstream deprecated `authkey` in favor of OAuth (client ID + client secret). When Areté migrates: bump this action's major version, swap the input shape, and update consumers in lockstep. Tracked in the parent epic.

## Bumping the upstream SHA

```bash
gh api /repos/tailscale/github-action/git/refs/tags/v3 --jq '.object.sha'
gh api /repos/tailscale/github-action/git/refs/tags/v4 --jq '.object.sha'
```

Update the SHA in `action.yml` and the trailing comment. Bump this action's version per [`CONTRIBUTING.md`](../../CONTRIBUTING.md#versioning).

## Versioning policy

Inherits the repo-level `vX.Y.Z` versioning. Behavior changes follow:

| Change | Bump |
|---|---|
| Internal refactor, no caller-visible change | patch |
| New optional input, default unchanged | minor |
| Renamed/removed input, default change, breaking shape change | **major** |
| Upstream SHA bump within same upstream major | minor or patch |
| Upstream SHA bump across upstream majors (v3 → v4) | **major** |
