# Runners and CI

Where a job runs, why, and the traps on the self-hosted host. Written 2026-08-26
after a migration to that host broke two release pipelines and caused a
production outage. Decision record: [#116](https://github.com/aretecp/github-actions/issues/116).

## The rule

| Job | Runner |
|---|---|
| CI, anything containerized | `[self-hosted, omarchy]` |
| Dev deploys | `[self-hosted, omarchy]` |
| **Release, prod deploys** | **`ubuntu-latest`** |
| A job whose tooling conflicts with the runner's own state | `ubuntu-latest`, with the reason inline |

The release path is hosted on purpose. It is how a fix reaches production, and
the self-hosted box is unreachable exactly when you most need to ship. Those
jobs run in seconds, so the minutes were never worth the coupling.

The last row is real: `arilearn-phx`'s `deploy-dev.yml` stays hosted because it
calls `tailscale/github-action@v3`, and the runner is already a tailnet node.

**Consumers choose with the `runner:` input** on any shared workflow. It defaults
to `ubuntu-latest`, so a repo that passes nothing is hosted. That input is also
the fail-back: one line flips a repo off the self-hosted box when it is down or
being upgraded.

## Concurrency

Every shared workflow has a `concurrency` block. Two policies:

**`cancel-in-progress: true`** — only the newest run's output matters.
`pr-to-main-hooks` (fires on `synchronize`, so every push to a promotion PR was
starting a fresh Claude call to regenerate the same summary) and
`claude-issue-triage` (the newest `@claude` comment is the one being answered).

**`cancel-in-progress: false`** — a queued run is correct, a cancelled one is a
mess. `release-shared` (stages a commit, pushes main, waits on CI, then tags —
killed partway leaves a staged commit and no tag), `deploy-vps-shared`
(half-applied compose state), `copy-prod-db-shared` (two overlapping copies leave
a dev DB matching neither snapshot), `rollback-vps-shared` (run when something is
already wrong).

## actionlint

`lint-workflows.yml` runs on every PR touching `.github/workflows/**` or
`actions/**`. It exists because a mistake here ships to every repo pinned `@v2`
at once, and reusable workflows get no other validation.

It runs the upstream pinned binary, not a wrapper action:
`raven-actions/actionlint@v2.0.0` npm-installs into the workspace root, then
resolves `@actions/tool-cache` from there instead of its own bundle and crashes
with `ERR_PACKAGE_PATH_NOT_EXPORTED` before linting anything.

`shellcheck` is off. These workflows take caller-supplied inputs this repo cannot
see, so SC2086-style advice on `${{ }}` interpolation is noise.

Run it locally before pushing a workflow change:

```sh
actionlint -color -shellcheck=
```

## Traps on the self-hosted host

Every one of these is the host not being the environment the job assumed. None
was a code bug.

**`runner` context is unavailable in job-level `env:`.** It does not warn — it
makes the workflow **invalid**, so every run fails at startup with no jobs and no
log, which is far harder to diagnose than whatever you were fixing. Use
`github.workspace` at job level, or scope the `env:` to the steps, where `runner`
*is* available. This shipped to two repos and silently stopped their releases.

**npm cannot write its cache.** `$HOME` on the runner is
`/opt/arete/actions-runner`, which it cannot create, so `npm ci` dies with
`ENOENT: mkdir '/opt/arete/actions-runner/.npm'` (exit 254). Set
`npm_config_cache`, and `npm_config_prefix` if you `npm install -g`, then append
the global bin to `GITHUB_PATH`.

**npm may not be present at all.** `claude-issue-triage` and `pr-to-main-hooks`
called `npm install -g` with no `actions/setup-node` step, relying on
`ubuntu-latest` having it preinstalled. Add setup-node.

**`actions/setup-python` 404s** — "version not found for this operating system".
No manifest entry for Arch. Use `ghcr.io/aretecp/ci-python-uv:3.12` instead.

**Root-run container jobs leave uid-0 files** in the shared per-repo `_work`
workspace, and the next job's `git clean -ffdx` needs write on the parent to
delete them. `chmod a+rX` is not enough. Add a final `if: always()` step:

```sh
chown -R "$(stat -c '%u:%g' .)" .
```

**Bare jobs can deadlock.** If the runner instance already carries uid-0
pollution, `actions/checkout`'s clean-and-recreate fallback fails as the non-root
runner user — and if that job gates others via `needs:`, nothing runs to
self-heal it. Containerize any job that checks out code; root bypasses ownership
checks regardless of ambient pollution.

**`git diff` hides a dubious-ownership failure.** In a container as root against
a workspace owned by another uid, `git diff <path>` reports
`warning: Not a git repository. Use --no-index...` while `git status` reports the
truth: `fatal: detected dubious ownership in repository at ...`. Reproduced in
`ci-python-uv:3.12` (git 2.39.5). Non-git steps pass throughout, because only git
checks ownership. Fix:

```sh
git config --global --add safe.directory "$GITHUB_WORKSPACE"
```

## Reducing wasted runs

- `concurrency` on every workflow, per the policies above.
- `paths-ignore` for documentation. **Name the paths; do not use `**/*.md`** —
  markdown under `src/` is often a code input (lumios ships `SKILL.md` library
  seeds and a `rubric.md` that drives behaviour). `*.md` matches root only.
- Do not put `paths-ignore` on a `push` to a release branch: `release.yml`
  consumes a CI `workflow_run` for the exact SHA, so skipping CI strands the
  release gate.
- Before adding a path filter, check whether the check is **required** in branch
  protection. A required check that never reports leaves PRs pending forever; the
  alternative is an always-running `changes` gate job with the heavy jobs
  conditional on it.

## Before you move a job to the self-hosted runner

1. Does it run in a container? If not, expect the traps above.
2. Does it need node, python or npm? Provision explicitly; assume nothing.
3. Is it on the path that ships to production? Then leave it hosted.
4. Run `actionlint` locally.
5. After merging here, **move the `v2` tag** — consumers pin it, so a merge alone
   changes nothing:

```sh
git fetch origin && git tag -f v2 origin/main && git push -f origin v2
```
