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

Most releases happen **automatically** on push to `main`. Override manually only for pre-releases or out-of-band cuts.

### Auto-release (default — every push to main)

The Release workflow (`.github/workflows/release.yml`) runs on every push to `main`. It reads the merge commit's conventional prefix and decides:

| Commit subject pattern | Action |
|---|---|
| `feat: ...` or `feat(scope): ...` | Auto-bump **minor** + cut release |
| `fix: ...` or `fix(scope): ...` | Auto-bump **patch** + cut release |
| `feat!:` / `fix!:` / contains `BREAKING CHANGE` | Auto-bump **major** + cut release |
| `chore:` / `docs:` / `refactor:` / `test:` / `style:` / `ci:` / `build:` | **Skip** — no release |
| Anything else | **Skip** — no release |

**Squash-merge convention.** Areté uses squash-merges, so the merge commit's subject is whatever was in the PR title. **Use a conventional prefix on PR titles** for auto-release to fire correctly.

### Sanity check (optional)

```bash
git fetch origin --tags
git log --oneline $(git describe --tags --abbrev=0 2>/dev/null || echo '')..origin/main
```

### Manual override (workflow_dispatch)

For pre-releases (e.g. `v2.0.0-rc.1`) or out-of-band cuts, override the auto-detect:

1. Go to **Actions → Release** → **Run workflow** in the GitHub UI.
2. Fill in:
   - **Branch:** `main`
   - **Version:** the explicit version (e.g. `v2.0.0-rc.1`). Leave blank to use the auto-detect path.
   - **Update moving major tag:** ✅ checked for stable releases. **Uncheck for pre-releases**.
3. Click **Run workflow**.

The workflow:
1. Determines version (auto-detect from commit prefix, OR uses the manual input)
2. Validates the version format (`vMAJOR.MINOR.PATCH` with optional `-prerelease`)
3. Verifies the tag doesn't already exist
4. Creates the annotated `vX.Y.Z` tag and pushes it
5. Force-updates the moving `vX` tag (unless pre-release or explicitly disabled)
6. Creates a GitHub Release with auto-generated notes (pre-releases marked as such)
7. Posts a step-summary with links

### Manual fallback

If the workflow is broken or unavailable, the manual procedure is:

```bash
VERSION=v1.0.1   # the version you're cutting
MAJOR=v1         # major component

git checkout main && git pull origin main
git tag -a "$VERSION" -m "$VERSION" && git push origin "$VERSION"
git tag -fa "$MAJOR" -m "Tracking $MAJOR.x" && git push --force origin "$MAJOR"
gh release create "$VERSION" --title "$VERSION" --generate-notes
```

The `--force` on `$MAJOR` is intentional — see the warning under "Moving major tag" below.

### Moving major tag — the one legitimate force-push

The `vX` moving tag is the **only** force operation in this repo. Every patch and minor under the same major requires advancing `vX` to the new annotated tag. The release workflow handles this automatically; the manual fallback does it explicitly. Future contributors should not interpret it as a mistake or push for `--no-force` policies on tags.

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
