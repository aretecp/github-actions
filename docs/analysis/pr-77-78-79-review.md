# Review — PRs #77, #78, #79

Reviewed 2026-08-06 against `main` @ `324e181`. All three target `main`, which is correct for
this repo (`base_branch: main` in `AGENTS.md`, and history shows feature→main).

> ## Outcome — recorded 2026-08-06, after the fact
>
> **#79 merged at 14:44, before this review was posted at 16:22.** The review is on a closed PR;
> it did not gate anything. What became of its findings:
>
> | Finding | Outcome |
> |---|---|
> | rust-tauri baked components target the wrong toolchain (§3) | **Fixed independently** by `#80`, same conclusion, verified differently (`rustup run stable cargo clippy --version` vs the default toolchain's). |
> | `git` on the omarchy host (§5) | **Obsolete — I reviewed a stale diff.** The merged workflow runs on `ubuntu-latest`, not `[self-hosted, omarchy]`, with an added comment explaining why it must: this repo is PUBLIC and the org runner group sets `allows_public_repositories: false`, so a self-hosted job here queues forever. There is no omarchy host in the path. |
> | `DOCKER_CONFIG` under `/tmp` on a shared runner (§10) | **Obsolete, same reason.** `DOCKER_CONFIG` was removed entirely before merge; the hosted runner is ephemeral and cleanup is now just `docker logout`. |
> | **`MIX_HOME`/`HEX_HOME` (§1)** | **Was live on `main`.** Fixed in `aretecp/github-actions#83`. |
> | **Smoke blind spot + rebar tautology (§2)** | **Was live on `main`.** Fixed in `aretecp/github-actions#83`. |
> | `$HOME` build-time guard (long-term item 4) | **Deferred, not in `#83`.** A naive `find /root -mindepth 1` guard fails on the images as built: the patched `ci-elixir:1.18.4-otp-27` still leaves 16 entries under `/root` — `.bashrc` and `.profile` from the base image, `.cache/uv`, `.config/uv/uv-receipt.json`, and a `/root/.local/bin/python3.12` shim that `uv python install` writes regardless of `UV_PYTHON_INSTALL_DIR`. The guard needs a curated allow-list, which is design work; it should not delay the MIX_HOME fix. |
> | Concurrency key, `timeout-minutes`, arch-pinned libpq, README tense (§8–11) | Not done. Low priority; see `pr-77-78-79-fixes.md` §A1.4. |
>
> **Two lessons worth keeping.**
>
> 1. **Check merge state before writing a long review.** Landing after the merge meant the fix needed
>    a fresh PR against `main` rather than a change request, with consumer migrations already in
>    flight.
> 2. **Re-pull the diff before writing, not just at the start.** `gh pr diff` is a snapshot. PR #79
>    was revised between the diff captured for this review (head `0221705`) and its merge — runner
>    moved to `ubuntu-latest`, `checkout` bumped v4→v5, `github-script` v7→v8, `DOCKER_CONFIG`
>    deleted — so two findings critiqued code that no longer existed.
>
> The two real defects (`MIX_HOME`, the smoke blind spot) survived all of that and were still live on
> `main`, so the review was worth doing. But two of eleven findings were noise, which is the cost of
> reviewing a stale snapshot.
>
> **#78's recommendation changed** after areteos reported that `pr-to-main-hooks.yml` already
> contains the correct footer mechanism — see the update block in `pr-77-78-79-fixes.md`.

**Verdicts as written at review time**

| PR | Verdict | Blocking? |
|---|---|---|
| #77 `fix(vps-deploy)`: compose-up timeout | **Approve.** Correct, backwards compatible, fixes a real failure. | No |
| #78 `feat(release)`: close released issues | **Approve with changes.** Inert on merge (opt-in, nobody sets it). Fix before any repo opts in. | Not to merge; yes before opting in |
| #79 `feat(images)`: CI base images | **Request changes.** One confirmed defect that breaks `areteos` + `arilearn-phx` CI, and the smoke tests structurally cannot catch it. | **Yes** |

Consumer inventory (verified by org-wide code search):

- `deploy-vps-shared.yml` / `rollback-vps-shared.yml` → `areteos`, `bd-pulse`, all pinned `@v2`
- `release-shared.yml` → `areteos` only, pinned `@v1`
- Container CI jobs affected by #79 → `areteos` (ci.yml, desktop-ci.yml), `areteos-py` (backend +
  frontend), `arilearn-phx` (two jobs), `beacon`

---

## PR #77 — compose-up timeout

The diagnosis is right and the fix is the right shape. Verified against the file: compose-up was
indeed the only `appleboy/ssh-action` step without `command_timeout`, and the timeout table in the
PR body matches `actions/vps-deploy-core/action.yml` exactly (backup 5m, pre-compose 10m,
healthcheck 5m, two steps on the 10m default). `appleboy/ssh-action@v1.2.0` is pinned consistently
across all six steps and takes a Go duration, so `30m` is valid.

**No consumer breaks.** New optional input with a default; `areteos` and `bd-pulse` are all on
`@v2`, none of them pass `compose-build` (so all default to `true` and all build on the VPS), and
none of the calling jobs set `timeout-minutes` that would cap the new ceiling. Every consumer gets
the fix for free.

### 1. `areteos` dev and prod deploys share one VPS working tree — different concurrency groups (Medium, pre-existing, amplified by this PR)

- `areteos/.github/workflows/deploy-dev.yml` → `concurrency.group: deploy-dev`
- `areteos/.github/workflows/deploy-prod.yml` → `concurrency.group: deploy-prod`
- Both → `repo-dir: /home/${{ vars.VPS_USER }}/areteos`

Different groups, one working tree. They can run concurrently and race `git checkout --force` in
that tree. This is not speculative — `vps-deploy-core/action.yml` says so itself in the compose-up
step:

> There is intentionally NO `--remove-orphans`: on a shared VPS it would delete other stacks'
> containers (Traefik, **or the prod project that shares this dir**).

And `bd-pulse` already fixed exactly this, deliberately:

> Shared with deploy-dev (#2299): both deploy from the SAME VPS checkout (`/home/sglyon/bd-pulse`),
> so they must serialize — a concurrent dev + prod deploy would race `git checkout --force` in that
> one working tree.

Raising compose-up 10m → 30m triples the window in which a dev cold build is holding that tree
while a prod tag deploy checks out over it. Worst case, prod containers get built from `develop`
source.

**Fix:** give `areteos` one shared concurrency group across deploy-dev/deploy-prod, copying
`bd-pulse`'s pattern. Should ship in the same batch as this PR, in the `areteos` repo. Not a reason
to hold #77.

### 2. `deploy-dev` uses `cancel-in-progress: true` (Low)

With a 30m ceiling, a cold build is far more likely to be cancelled mid-build by a newer `develop`
push. Killing the ssh-action does not stop the remote `docker compose build`, so the cancelled
build keeps compiling on the VPS while the replacement deploy starts a second one in the same tree.
Consider `cancel-in-progress: false` for deploy-dev, consistent with `bd-pulse`.

### 3. The same failure class is left unfixed one step earlier (Low)

`pre-compose-up-script` is hardcoded `command_timeout: 10m` in `vps-deploy-core`, and that is the
hook `rollback-vps-shared.yml` uses to run the DB restore (`pre-compose-up-script:
${{ steps.build-restore-script.outputs.restore-script }}`). A large restore hits the identical
silent `Run Command Timeout`. Exposing it the same way is a two-line addition; worth doing now
while the reasoning is fresh, or filing.

---

## PR #78 — close issues released by a develop→main promotion

The design notes are unusually good, and the empirical findings behind them check out. I verified
the consumer claim independently: `release-shared.yml` is **byte-identical** at the `v1` tip
(`7d245ad`, 2026-05-27) and the `v2` tip (`11e24bb`), so moving `areteos` to `@v2` is safe for that
file as stated.

Merging is inert — `default: false` and no repo sets it. Everything below is about the state it
needs to be in before a repo opts in.

### 1. The keyword scan matches quoted and fenced text (High)

I ran their exact regex over a body with edge cases. Matched: `12 34 56 81 83 84 85 88 89`.

Two of those are wrong:

```
Line 10:  Closes #83      <- inside a ``` fenced code block   -> MATCHED
Line 12:  > Closes #84    <- inside a blockquote              -> MATCHED
Line  7:  This does not close #81 yet                         -> MATCHED
```

This is the bug they already met once and mitigated narrowly. **PR #78's own description contains a
fenced code block holding `Closes #123` and `Closes #456`** — the very placeholders the first dry
run tried to act on. The base-branch filter saves them only because the promotion PR is
`base=main`. A *feature* PR (`base=develop`) whose body documents a Closes line, quotes the
`<!-- auto-closes -->` template, or pastes another PR's body gets acted on with no filter in the way.

This interacts badly with `pr-to-main-hooks.yml`, which writes `Closes #N` footers into PR bodies —
the greedy-harvester behaviour already recorded for that workflow.

The `#81` case ("does not close #81 yet") matches GitHub's own greediness, so it is defensible —
but note it undercuts the stated rationale for excluding titles ("would close on a passing mention
like *fixes #12 regression*"). Bodies have the same exposure; only titles were protected.

**Fix:** strip fenced blocks and leading `>` before matching, and anchor the keyword to a line start
(optionally after `- ` / `* `), which is how these are actually written.

### 2. Every silent-failure path writes nothing to the summary (Medium)

`set -uo pipefail` without `-e` is a deliberate and correct choice here, but it means two real
failures land as silence:

- `git rev-list "$BEFORE_TAG..$LATEST_TAG"` fails (e.g. `gh release view` returns a release whose
  tag is not in the local clone) → `PRS` empty
- `gh api .../pulls 2>/dev/null` hits a 403 rate limit → swallowed → `PRS` empty or short

Both fall into `[[ -z "$PRS" ]] && { echo "No pull requests in range."; exit 0; }`, which exits
**before** the `$GITHUB_STEP_SUMMARY` block. So the summary is absent, and absent is
indistinguishable from "nothing to close". For a feature whose entire value is bookkeeping you have
to trust, every exit path should write a summary line — including "scanned N commits, found 0 PRs".
Also drop the `2>/dev/null` on the per-commit call, or check its status.

### 3. One serial API call per commit in the range (Medium)

```bash
PRS=$(for sha in $(git rev-list "${BEFORE_TAG}..${LATEST_TAG}"); do
        gh api "repos/$REPO/commits/$sha/pulls" --jq '.[].number' 2>/dev/null
      done | sort -un)
```

`GITHUB_TOKEN` is capped at 1,000 requests/hour/repo, shared with whatever `semantic-release` just
spent. The 1.43.0 promotion shipped 12 issues but the commit count behind it is much larger, and
per #2 exhausting the budget fails silently. A single GraphQL query using `associatedPullRequests`
over the range replaces the whole loop. At minimum, log the commit count so the cost is visible.

### 4. `BEFORE_TAG` is an unfiltered `git describe` promoted to a range boundary (Medium)

`steps.before` is `git describe --tags --abbrev=0`, which matches **any** tag. In the existing
deploy-trigger step that only ever feeds an equality check, so imprecision is harmless. This PR
makes it a `git rev-list` boundary, where a stray non-version tag reachable from HEAD silently
narrows or widens the scanned range. Add `--match 'v[0-9]*'`.

### 5. No merged-state guard on the discovered PRs (Low — hardening)

The script trusts `commits/{sha}/pulls` to return only the merged PR. The API docs support that for
commits present in the default branch, and a probe against `areteos` was consistent with it, so
**this is not a confirmed bug** — but the docs are ambiguous about open PRs and the code never
checks. `gh pr view` is already being called for `baseRefName`; adding `state,mergedAt` to that same
`--json` costs one field and removes the doubt.

### 6. Ordering: closes issues before the prod deploy is even triggered (Low)

The step sits *before* `Trigger production deploy if new release`. Issues get closed with
"Released in vX" while the deploy has not been triggered, let alone succeeded — and per #3 the step
can add minutes of API calls ahead of the trigger. Move it after the deploy trigger.

### 7. Two forms GitHub accepts are not matched (Low)

- `Closes https://github.com/aretecp/<repo>/issues/80` — same-repo URL form
- `fixes#87` — no whitespace

Both are left open, so this errs in the safe direction. Worth stating in the input description so
nobody assumes full parity with GitHub. (Correctly *not* matched: bare `#82`,
`aretecp/other-repo#78`, `Closes aretecp/other-repo#79`, and `closing #86` — `closing` is not a
GitHub keyword. The `\s+#` guard does what the PR claims.)

### 8. Stale comment in the consumer (Info)

`areteos/.github/workflows/release.yml` says "Bump the `@v1` ref there to pick up patch/minor fixes
automatically". False since `v1` froze on 2026-05-27. Consequence-free so far (see the
byte-identical finding above), but fix it in the `@v2` migration PR.

---

## PR #79 — CI base images

The premise is sound and this is the largest win of the three. `areteos`, `areteos-py`,
`arilearn-phx` and `beacon` already run `container:` jobs, so the swap really is a one-line change
per job. Three of the six images are clean parity matches:

- `ci-python-uv:3.12` — exactly `areteos-py` backend's package set (git, ca-certificates,
  build-essential, libpq5, chromium) and it retires the apt-archive cache dance
- `ci-python:3.12` — covers `beacon`; `UV_INSTALL_DIR=/usr/local/bin` correctly removes beacon's
  `$HOME/.local/bin` `GITHUB_PATH` append
- `ci-node:22` — exactly `areteos-py` frontend's set (git, ca-certificates)

Also correct and easy to get wrong: `ca-certificates` is installed *before* `mix local.hex`. I broke
a replica by omitting it and `mix local.hex` fails outright.

The two Elixir images and the Rust image have problems.

### 1. Baked Hex/Rebar is invisible in GitHub Actions container jobs (High — confirmed)

Both Elixir Dockerfiles run `mix local.hex --force && mix local.rebar --force` at build time, where
`HOME=/root`. GitHub Actions container jobs run with `HOME=/github/home`.

Confirmed from a real `areteos` run (`31112096355`, 2026-08-06 14:41Z):

```
##[command]/usr/bin/docker create ... -e "HOME=/github/home" ...
  -v ".../_work/_temp/_github_home":"/github/home" ... elixir:1.18.4-otp-27-slim
Install Hex + Rebar   * creating /github/home/.mix/archives/hex-2.5.1
Install Hex + Rebar   * creating /github/home/.mix/elixir/1-18-otp-27/rebar3
```

Reproduced locally against a faithful replica of the PR's Dockerfile:

```
A) docker run (HOME=/root)              -> hex: ok        rebar: ok
B) docker run -e HOME=/github/home      -> ** (Mix) The task "hex.info" could not be found
   baked artifacts live at:                /root/.mix/archives/hex-2.5.1
                                           /root/.mix/elixir/1-18-otp-27/rebar3
   /github/home/.mix                    -> No such file or directory
```

So the moment the follow-up PR deletes `Install Hex + Rebar` from `areteos/ci.yml` and from **both**
`arilearn-phx` jobs, `mix deps.get` fails. This PR alone is harmless; the planned follow-ups break
two repos.

**Fix:** in both Elixir Dockerfiles, before the mix line:

```dockerfile
ENV MIX_HOME=/usr/local/lib/mix \
    HEX_HOME=/usr/local/lib/hex
RUN mix local.hex --force && mix local.rebar --force
```

Worth noting this exact problem was already solved for uv in the same file
(`UV_INSTALL_DIR=/usr/local/bin`, `UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python`), and the smoke
test even says *"The managed 3.12 must resolve from the shared install dir, not from `$HOME`."* The
reasoning was right; it just wasn't applied to Mix.

### 2. The smoke tests cannot catch #1, and one assertion is a tautology (High — confirmed)

`docker run` defaults to the image's `HOME=/root`, so **every** HOME-scoped regression passes the
smoke gate. That undercuts the PR's central safety claim ("a missing package is a red check here
instead of six repos failing their next run") for the entire class of tools installed into `$HOME`.

Separately, this line asserts nothing:

```sh
mix help local.rebar > /dev/null && echo "rebar: ok"
```

`local.rebar` is a built-in Mix task, so `mix help local.rebar` succeeds on a vanilla
`elixir:1.18.4-otp-27-slim` where `local.rebar` was never run — confirmed. It passes whether or not
rebar3 is installed.

**Fixes:**

- Run the smoke step as `docker run --rm -e HOME=/github/home ...` — one flag, catches the whole class
- Assert rebar for real, e.g. `ls "${MIX_HOME:-$HOME/.mix}"/elixir/*/rebar3`

### 3. rust-tauri's baked clippy/rustfmt target a toolchain the consumer never uses (Medium — confirmed)

`rust:1.97-slim-bookworm` ships exactly one toolchain, named by version — confirmed:

```
$ docker run --rm rust:1.97-slim-bookworm rustup toolchain list
1.97.1-<arch>-unknown-linux-gnu (active, default)
```

There is no `stable` toolchain. The Dockerfile's `rustup component add clippy rustfmt` runs with no
`rust-toolchain.toml` in the build context, so it targets `1.97.1`. But
`areteos/desktop/rust-toolchain.toml` is:

```toml
[toolchain]
channel = "stable"
components = ["rustfmt", "clippy"]
```

At runtime, in `desktop/`, rustup resolves `stable` — a different toolchain — and downloads it fresh
on the first cargo call. `desktop-ci.yml`'s own comment states the dependency the image misses:

> Add them from `desktop/` so rust-toolchain.toml's `stable` override is the target.

Consequences:

- The bake is a **no-op**. Deleting the consumer's `Add clippy and rustfmt components` step is safe
  (the toml's `components` list covers it), but nothing is saved.
- The real per-run cost — downloading the `stable` toolchain — remains, and
  `Swatinem/rust-cache` does not cover it: it caches `CARGO_HOME` and `target`, not
  `RUSTUP_HOME=/usr/local/rustup`.
- The tag `ci-rust-tauri:1.97` does not describe the compiler the consumer actually uses, which
  contradicts `images/README.md`'s "the moving tag names the contract".

**Fix:** either `RUN rustup toolchain install stable --component clippy rustfmt` in the image, or
pin `desktop/rust-toolchain.toml` to the image's version. The former preserves current behaviour and
actually removes the download.

### 4. The workflow itself has never run (Medium)

Verification is "all six built locally on `kenya`" — that validates the Dockerfiles, not
`ci-images.yml`. Unexercised: the `actions/github-script` matrix hand-off, GHCR login/push with
`GITHUB_TOKEN`, `DOCKER_CONFIG` under `/tmp`, the cleanup step, and #5 below. A `workflow_dispatch`
run on the branch before merge would cover all of it (PR events already skip publish, so a dispatch
is the only way to exercise the push path).

### 5. First workflow in the fleet to require `git` on the runner *host* (Medium)

Every existing self-hosted job sets `container:`, so `actions/checkout` runs inside the container and
uses the *image's* git — which is precisely why all of them apt-install git. `ci-images.yml` has no
`container:`, so both `actions/checkout` and `git rev-parse --short=7 HEAD` run on the omarchy host.

Given the fleet's stated premise ("the runner host only needs Docker"), host git may not be there.
If it isn't, checkout silently degrades to a tarball download with no `.git`, and `Compute tags`
then fails on `git rev-parse`. One-line pre-merge check: run `git --version` on omarchy.

### 6. Sequencing: consumer swaps must not merge before the packages are public (Medium)

`container.image` is pulled before any step runs, so a private package fails the job at startup with
a `denied` error and there is no in-workflow remedy — `container.credentials` becomes mandatory, and
a consumer's own `GITHUB_TOKEN` cannot read a package owned by a different repo without an explicit
grant. Both `README.md` and `images/README.md` already assert "Public packages, so no
`container.credentials` block is needed" in the present tense, which is not true until the manual
step happens.

Make "set the six GHCR packages to public" a hard gate ahead of any follow-up PR, and confirm whoever
does it has org-owner rights on packages.

### 7. The weekly rebuild republishes moving tags with no consumer validation (Low)

`docker build --pull` refreshes the Debian base. A Sunday 04:17 run can move chromium — which
`areteos-py`'s PDF inertness test depends on — or gcc, under all consumers, with no diff and no PR.
The dated tags exist for exactly this, but nothing pins them.

Chromium already drifts today (the apt cache key busts on version change and the current candidate
gets installed), so this is not a regression — the drift just relocates to a cron in another repo.
Options: have the scheduled run publish only the dated tag plus a bot PR advancing consumers, or
accept it and note that Monday breakage is possible.

### 8. Concurrency lets the cron and a main push race the same tags (Low)

`group: ci-images-${{ github.event_name }}-...` puts the event in the key, so
`ci-images-schedule-main` and `ci-images-push-main` are separate groups and can push identical moving
tags concurrently. Drop the event from the key for publishing events. Related: `cancel-in-progress:
true` on a publishing workflow can cancel mid-`docker push` and leave some of the six images advanced
and others stale.

### 9. No `timeout-minutes` on the build jobs (Low)

A hung `docker build` holds a scarce self-hosted slot for the 360-minute default.

### 10. `DOCKER_CONFIG` under `/tmp` on a shared runner (Low)

`docker login` writes the base64 `GITHUB_TOKEN` to
`/tmp/docker-config-<run_id>-<job_index>/config.json`. Cleanup is correct (`if: always()`, plus
`docker logout`), but on a shared self-hosted host any other job on the box can read it during the
window. The comment rejects `RUNNER_TEMP` as being under a read-only root — worth re-checking: the
`areteos` container-create line shows `_work/_temp` mounted read-write.

### 11. Single-arch, with the arch hardcoded in one assertion (Low)

`images/python-uv-3.12/smoke.sh` tests `/usr/lib/x86_64-linux-gnu/libpq.so.5`. Prefer
`ldconfig -p | grep -q libpq.so.5` so the assertion is not arch-pinned. No multi-arch build; fine
while every runner is x86_64, but the manifest is the natural place to record that assumption.

### 12. `arilearn-phx` is two jobs, not one (Nit)

`manifest.json` and `images/README.md` list `arilearn-phx (ci.yml)` as a single consumer. It has two
container jobs — `Build & Test` and the doc-intel eval gate — both of which install Hex + Rebar and
both of which finding #1 breaks.

---

## Recommended order

1. **Merge #77.** Open a companion `areteos` PR unifying the deploy-dev/deploy-prod concurrency group.
2. **Fix #78's** fence/quote greediness (§1) and silent-summary paths (§2), then merge. The rest can
   follow before any repo opts in.
3. **Hold #79** for `MIX_HOME`/`HEX_HOME` (§1), the smoke-test `HOME` flag and real rebar assertion
   (§2), and the rust toolchain decision (§3). Then: `workflow_dispatch` on the branch → merge →
   make packages public → *then* the consumer swap PRs.

## How the findings were checked

- Diffs read in full; timeout tables and step lists verified against the files on `main`
- Consumer shims fetched for `areteos` and `bd-pulse` (deploy-dev, deploy-prod, rollback-prod,
  release) and CI workflows for `areteos`, `areteos-py`, `arilearn-phx`, `beacon`
- `v1`/`v2` tag targets resolved via `git ls-remote`; `release-shared.yml` byte-identity across them
  verified with `git diff`
- PR #78's regex executed against a 16-case body
- `HOME=/github/home` confirmed from `areteos` run `31112096355`; Hex/Rebar visibility, the
  `mix help local.rebar` tautology, and the rust toolchain name reproduced locally in Docker
