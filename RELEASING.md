# Releasing

How to cut a release of the actions in this repo. The semver bump rules and naming conventions live in [`CONTRIBUTING.md`](CONTRIBUTING.md#versioning) — this doc covers the *procedure*.

## Versioning model

This repo uses **single-repo versioning**. One annotated `vX.Y.Z` tag per release; one moving `vX` tag per major. Both apply to *every* action in `actions/*` simultaneously.

Consumers pin per-action via path:

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1.0.0
- uses: aretecp/github-actions/actions/load-infisical-secrets@<full-sha>
```

When a second action ships, both share the same `v1`/`v2` cadence. If divergent release cycles become painful, switch to per-action tags (`load-infisical-secrets/v1`) — that's a future migration, not how this repo starts.

## Pre-release checklist

- [ ] All open PRs targeting this release are merged.
- [ ] **Validation gate.** Currently: a real consumer (the pilot in #6, or another live workflow) has exercised every changed action against a real Infisical project since the last release. Re-enable a workflow-based smoke gate by reopening #4 if/when that becomes worth the public-repo logging tradeoff.
- [ ] Action READMEs reflect the inputs/outputs as of the current `main`.
- [ ] Root README's "Available actions" table reflects the new version (status column shows `v1.0.0`, not `_in development_`).
- [ ] `CONTRIBUTING.md` is up to date if any conventions changed.

## Picking the version

| Change | Bump |
|---|---|
| New action; no change to existing actions | minor |
| Internal refactor or doc-only change | patch |
| Bug fix in an existing action, no caller-visible behavior change | patch |
| New optional input or new behavior, default unchanged | minor |
| Renamed/removed input or output, default change, breaking shape change to any action | **major** |
| Upstream SHA bump with no caller-visible change | patch |
| Upstream SHA bump that changes caller-visible behavior | minor or major as appropriate |

Once the version is chosen, the rest is mechanical.

## Procedure

Run from a clean local `main` checked out at the commit you want to release.

```bash
# 1. Make sure local main is up to date
git checkout main
git pull origin main

# 2. Sanity-check what's in this release
git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo '')..HEAD
# → review the commits; confirm they match your bump rationale
```

### 1. Annotated version tag

```bash
VERSION=v1.0.0   # set to the version you're cutting

git tag -a "$VERSION" -m "$VERSION"
git push origin "$VERSION"
```

The annotated `vX.Y.Z` tag is **immutable** once pushed. Don't rewrite it. If you cut a wrong version, cut the next patch — never amend a published tag.

### 2. Moving major tag

```bash
MAJOR=v1   # the major component of $VERSION

# Create or move the major tag to the same commit
git tag -fa "$MAJOR" -m "Tracking $MAJOR.x"
git push --force origin "$MAJOR"
```

> **The `--force` is intentional.** The `vX` moving tag is the *one* legitimate force operation in this repo. Every future patch and minor under the same major requires repeating this step to advance `vX` to the new annotated tag. Future contributors should not interpret it as a mistake or push for `--no-force` policies on tags.

### 3. GitHub Release

Generate release notes (or write them by hand for v1.0.0):

```bash
# auto-generate from commit history since the previous tag
gh release create "$VERSION" \
  --title "$VERSION" \
  --generate-notes
```

For a hand-curated release (recommended for `v1.0.0`):

```bash
# Write notes to a file first
cat > /tmp/release-notes-$VERSION.md <<'NOTES'
## Highlights
- ...

## Actions in this release
- `load-infisical-secrets@$VERSION` — ...

## Breaking changes
- None (or list them with migration steps)
NOTES

gh release create "$VERSION" \
  --title "$VERSION" \
  --notes-file /tmp/release-notes-$VERSION.md
```

A GitHub Release also creates a downloadable `.zip`/`.tar.gz` of the source — that's automatic; consumers won't typically use them since they pin via `uses:` refs.

## Post-release

- [ ] Verify `v1` resolves to the same commit as the new annotated tag:
  ```bash
  git ls-remote --tags origin | grep -E '/v1(\.|$)' | sort
  ```
  Both should point at the same SHA.
- [ ] Bump consumer repos that pin to a SHA (the pilot in #6, etc.) if they want the new version. Repos pinned to `@v1` get the upgrade automatically on their next workflow run.
- [ ] Close any "released in $VERSION" labeled issues / project-board cards.

## If something is wrong after release

- **Bug found in `vX.Y.Z`** → cut `vX.Y.Z+1` with the fix, then re-force `vX` to the new tag. Old patch stays where it is; consumers on `@v1` get the fix automatically.
- **Tag pushed by mistake to a non-stable commit** → cut a `vX.Y.Z+1` from the *correct* commit, re-force `vX`. The bad tag stays in history but is no longer pointed at by `vX`.
- **Major regression that needs immediate revert** → revert the offending commit on `main`, cut a new patch, force `vX` to the new patch. Don't try to rewrite history of `main` to "remove" the bad release.

The rule of thumb: **only the moving `vX` tag changes after a push. Everything else is append-only.**
