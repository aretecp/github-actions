# Fixes for PRs #77 / #78 / #79 — drafts for review

> ## Status update — 2026-08-06, after the areteos finding
>
> **Done:**
> - Item 2 from the long-term list shipped as `aretecp/github-actions#81` — VPS operations now
>   serialise on the deploy target inside the three shared workflows. This supersedes issue **B1**
>   below: the fix landed in the shared repo rather than per-consumer, so no areteos change is needed.
> - Bucket A1 posted as a review comment on `#79`.
> - Bucket A2 posted as a review comment on `#78`, **substantially revised** — see below.
>
> **A2 is superseded.** areteos reported that `pr-to-main-hooks.yml` already contains the whole
> `Closes #N` footer mechanism and it is correct; the failure is upstream in `Gather PR context`
> (lines ~188–199), which harvests bare `#N` from **commit messages** while the declarations live in
> the bodies of the feature PRs merged into `develop`. Reproduced: `aretecp/areteos#1557` yields one
> candidate (`#1545`), which is a PR, so validation drops it → empty footer.
>
> That makes the footer path the better home for `#78`'s discovery logic — GitHub does the closing,
> a human sees the footer before merging, and it retires four of the A2 findings outright
> (`git describe` bounding, the per-commit rate-limit loop, step ordering, and the report-mode
> request). The posted review recommends redirecting rather than patching. **A2.2, A2.4 and A2.6
> below are no longer recommended.** A2.1, A2.3 and A2.5 still apply wherever the logic lands.
>
> **B5 is now more than cosmetic:** if `#78` moves into `pr-to-main-hooks.yml`, areteos needs that
> workflow on a current ref, not just `release-shared.yml`.

Nothing else has been filed. Confirm what you want and I'll create it.

Two buckets, because filing an issue for something that should just be fixed in an open PR is
process noise:

- **Bucket A — change requests on the open PRs.** Post as review comments; Spencer pushes to the
  existing branch. No issue.
- **Bucket B — new issues.** Separate work: different repo, or genuinely out of scope for the PR.

> **Note on cross-repo refs in every draft below:** all references to another repo's PR/issue are
> fully qualified (`aretecp/github-actions#79`), never bare `#79`. `pr-to-main-hooks.yml`'s
> auto-closes harvester turns a bare `#N` in a release-PR body into `Closes #N` against the *consumer*
> repo, which would close an unrelated issue. Keep this convention when editing the drafts.

---

# Bucket A — change requests on the open PRs

## A1. PR #79 — blocking

### A1.1 `MIX_HOME` / `HEX_HOME` — the one that breaks apps

**Why:** `mix local.hex` runs at build time where `HOME=/root`, so Hex and rebar3 land in
`/root/.mix`. GitHub Actions container jobs run with `HOME=/github/home`, so Mix never finds them.
Confirmed from areteos run `31112096355` (`docker create ... -e "HOME=/github/home"`, and its own
step logs `* creating /github/home/.mix/archives/hex-2.5.1`), and reproduced locally: `mix hex.info`
succeeds under `docker run` and fails with `** (Mix) The task "hex.info" could not be found` under
`-e HOME=/github/home`.

The PR as written is harmless. The **planned follow-ups break `areteos` and both `arilearn-phx` jobs**
the moment they delete `Install Hex + Rebar`.

**Fix** — both `images/elixir-1.18.4-otp-27/Dockerfile` and `images/elixir-1.19.5-otp-28/Dockerfile`:

```diff
-# Hex/Rebar are not preinstalled on the hexpm image.
-RUN mix local.hex --force && mix local.rebar --force
+# Hex/Rebar are not preinstalled on the hexpm image.
+#
+# MIX_HOME/HEX_HOME must be system paths, not $HOME. A GitHub Actions container
+# job runs with HOME=/github/home (a per-job mount), so anything installed to
+# /root/.mix at build time is invisible at runtime and `mix deps.get` fails with
+# "Could not find Hex". Same reasoning as UV_PYTHON_INSTALL_DIR below.
+ENV MIX_HOME=/usr/local/lib/mix \
+    HEX_HOME=/usr/local/lib/hex
+RUN mix local.hex --force && mix local.rebar --force
```

Both are image `ENV`, so they survive into the container job — the runner overrides `HOME` but not
`MIX_HOME`. This is the same mechanism the PR already uses correctly for uv.

### A1.2 Smoke tests can't catch A1.1, and the rebar assertion is a tautology

**Why:** the PR's safety argument is "a missing package is a red check here instead of six repos
failing their next run." `docker run` defaults to the image's `HOME=/root`, so **every** `$HOME`-scoped
regression passes — including A1.1. One flag closes the whole class.

Separately, `mix help local.rebar` succeeds on a vanilla `elixir:1.18.4-otp-27-slim` where
`local.rebar` was never run (it's a built-in Mix task). Confirmed. That line asserts nothing.

**Fix 1** — `.github/workflows/ci-images.yml`, make the smoke run match Actions:

```diff
       - name: Smoke test
         run: |
-          docker run --rm '${{ steps.tags.outputs.moving }}' \
+          # Mirror a GitHub Actions container job: HOME is /github/home, an empty
+          # per-job mount. Without this the smoke test runs as HOME=/root and
+          # silently passes anything installed into the image's own home dir.
+          docker run --rm \
+            -e HOME=/github/home --tmpfs /github/home \
+            '${{ steps.tags.outputs.moving }}' \
             bash -euc "$(cat 'images/${{ matrix.dir }}/smoke.sh')"
```

**Fix 2** — both Elixir `smoke.sh` files:

```diff
 mix hex.info > /dev/null && echo "hex: ok"
-mix help local.rebar > /dev/null && echo "rebar: ok"
+# rebar3 must actually be on disk. `mix help local.rebar` passes on any Elixir
+# install whether or not local.rebar was ever run, so it asserts nothing.
+ls "${MIX_HOME:?MIX_HOME unset}"/elixir/*/rebar3
```

Fix 2 depends on A1.1 landing (it reads `MIX_HOME`), which is the point — the assertion now fails
loudly if someone drops the `ENV`.

### A1.3 rust-tauri bakes components for a toolchain the consumer never uses

**Why:** `rust:1.97-slim-bookworm` ships exactly one toolchain, named by version — confirmed:

```
$ docker run --rm rust:1.97-slim-bookworm rustup toolchain list
1.97.1-<arch>-unknown-linux-gnu (active, default)
```

No `stable` toolchain exists. The Dockerfile's `rustup component add` has no `rust-toolchain.toml` in
context, so it targets `1.97.1`. But `areteos/desktop/rust-toolchain.toml` is `channel = "stable"`,
so at runtime rustup downloads `stable` fresh on the first cargo call. `desktop-ci.yml`'s own comment
already names this dependency: *"Add them from `desktop/` so rust-toolchain.toml's `stable` override
is the target."*

Not a break — the toml's `components = ["rustfmt", "clippy"]` covers the deleted step — but the bake
is a **no-op**, the real per-run cost stays, and `Swatinem/rust-cache` does not cover it (it caches
`CARGO_HOME` and `target`, not `RUSTUP_HOME=/usr/local/rustup`).

**Fix** — `images/rust-tauri/Dockerfile`:

```diff
-# The slim image ships the toolchain without clippy/rustfmt. desktop/
-# rust-toolchain.toml pins the `stable` channel, which is what this tag
-# bootstraps, so adding the components here targets the same toolchain the
-# workspace resolves.
-RUN rustup component add clippy rustfmt
+# desktop/rust-toolchain.toml pins `channel = "stable"`, and this image's only
+# toolchain is named by version (1.97.x) — `stable` is a DIFFERENT toolchain that
+# rustup would otherwise download on the first cargo call, uncached
+# (Swatinem/rust-cache covers CARGO_HOME and target, not RUSTUP_HOME). Install it
+# here with its components so the consumer downloads nothing at runtime.
+RUN rustup toolchain install stable --component clippy rustfmt
```

Alternative if you'd rather not carry two toolchains: pin `desktop/rust-toolchain.toml` to the image
version instead. I'd take the image change — it preserves current behaviour and is the only one of
the two that actually removes the download.

Either way, flag that `ci-rust-tauri:1.97` does not describe the compiler the consumer uses, which
contradicts `images/README.md`'s "the moving tag names the contract". Worth a line in that README.

### A1.4 Non-blocking one-liners, same PR

```diff
 concurrency:
-  group: ci-images-${{ github.event_name }}-${{ github.head_ref || github.ref_name }}
+  # No event_name in the key: schedule and push must NOT be separate groups, or a
+  # Sunday cron and a main merge race each other pushing the same moving tags.
+  group: ci-images-${{ github.head_ref || github.ref_name }}
   cancel-in-progress: true
```

```diff
   build:
     name: ${{ matrix.image }}:${{ matrix.tag }}
     needs: discover
     runs-on: [self-hosted, omarchy]
+    # A hung docker build otherwise holds a scarce self-hosted slot for the 360m default.
+    timeout-minutes: 45
```

```diff
-test -e /usr/lib/x86_64-linux-gnu/libpq.so.5 && echo "libpq5: ok"
+ldconfig -p | grep -q libpq.so.5 && echo "libpq5: ok"
```

And in both READMEs, "Public packages, so no `container.credentials` block is needed" is present
tense for something that isn't true yet — reword to note it depends on the post-merge visibility step
(tracked by issue B3).

### A1.5 Pre-merge checks, not code changes

1. **`git --version` on the omarchy host.** `ci-images.yml` is the first workflow in the fleet with no
   `container:`, so `actions/checkout` and `git rev-parse --short=7 HEAD` run on the *host*. Every
   existing self-hosted job runs checkout inside its container against the *image's* git — which is
   exactly why they all apt-install it. If the host has no git, checkout silently degrades to a
   tarball with no `.git` and `Compute tags` then fails.
2. **One `workflow_dispatch` run on the branch before merge.** Verification so far is "built locally
   on kenya", which validates the Dockerfiles, not the workflow. PR events skip publish, so a
   dispatch is the only way to exercise the github-script matrix hand-off, GHCR login/push,
   `DOCKER_CONFIG`, and cleanup.

## A2. PR #78 — fix before any repo opts in

Merging is inert (`default: false`, nobody sets it), so these don't block the merge — but they should
land before the areteos opt-in.

### A2.1 Strip fenced blocks and blockquotes before matching

**Why:** I ran the PR's exact regex over a 16-case body. It matches `Closes #83` inside a ``` fence
and `> Closes #84` in a blockquote. **PR #78's own description contains a fenced block holding
`Closes #123` and `Closes #456`** — the placeholders that bit the first dry run. The base-branch
filter only saves it because promotion PRs are `base=main`; a *feature* PR (`base=develop`) that
documents a Closes line, quotes the `<!-- auto-closes -->` template, or pastes another PR's body has
no guard at all. This is a real divergence from GitHub's own parser, which ignores fenced code.

```diff
-            BODY=$(gh pr view "$pr" --repo "$REPO" --json body -q '.body // ""' 2>/dev/null) || continue
+            # Drop fenced code blocks and blockquotes first. GitHub's own parser
+            # ignores a Closes line inside a fence, and a PR that DOCUMENTS the
+            # release template (or pastes another PR's body) would otherwise have
+            # its example refs acted on — which is what the first dry run hit.
+            BODY=$(printf '%s\n' "$BODY" \
+                     | awk '/^[[:space:]]*```/ { f = !f; next } !f' \
+                     | grep -v '^[[:space:]]*>')
```

### A2.2 Add a report-only mode

**Why:** the regex still matches negated prose — "This does not close #81 yet" closes #81. That
matches GitHub's own greediness, so it's defensible, but on GitHub you see the linked-issues sidebar
before merging; here it happens unattended. The author already ran a manual dry run to build
confidence — making that a first-class mode costs almost nothing and directly serves the PR's own
stated principle that this should be "a decision rather than something a shared workflow starts doing
on its own."

The input is new in this PR, so changing its shape breaks nothing:

```diff
-      close-released-issues:
-        required: false
-        type: boolean
-        default: false
+      close-released-issues:
+        description: >-
+          `off` (default) — do nothing. `report` — resolve the issues a release
+          would close and write them to the step summary, closing nothing.
+          `close` — actually close them. Start on `report` for a release or two:
+          the description scan is a text match, so a body that merely mentions
+          "does not close #N" resolves as a target.
+        required: false
+        type: string
+        default: 'off'
```

Gate the `gh issue close` call on `== 'close'`, and keep the summary identical in both modes so
`report` shows exactly what `close` would have done.

### A2.3 Write a summary on every exit path, and stop swallowing errors

**Why:** `set -uo pipefail` without `-e` is the right call, but it turns two real failures into
silence. `git rev-list` failing (tag not in the local clone) or `gh api` hitting a 403 rate limit both
leave `PRS` empty → `"No pull requests in range"` → `exit 0` **before** the `$GITHUB_STEP_SUMMARY`
block. Absent summary is indistinguishable from "nothing to close". For a feature whose whole value
is bookkeeping you have to trust, silence is the worst outcome.

- Move summary writing into a function called before every `exit 0`, including a
  `scanned N commits, resolved 0 PRs` line.
- Drop `2>/dev/null` from the per-commit `gh api`, or check its status and surface a `::warning::`.

### A2.4 Bound the tag match

**Why:** `steps.before` is `git describe --tags --abbrev=0`, which matches **any** tag. Harmless in
the existing deploy-trigger step (equality check only), but this PR promotes it to a `git rev-list`
boundary, where a stray non-version tag reachable from HEAD silently changes the scanned range.

```diff
-      run: echo "tag=$(git describe --tags --abbrev=0 2>/dev/null || echo none)" >> "$GITHUB_OUTPUT"
+      run: echo "tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo none)" >> "$GITHUB_OUTPUT"
```

### A2.5 One `gh pr view` per PR instead of two, plus a state guard

**Why:** the loop calls `gh pr view` for `baseRefName` and again for `body`. One call returns both.
And nothing checks the PR is merged — `commits/{sha}/pulls` is documented to return the merged PR for
commits in the default branch and a probe against areteos was consistent with that, so this is
hardening rather than a confirmed bug, but the fields are free here.

```diff
-            BASE=$(gh pr view "$pr" --repo "$REPO" --json baseRefName -q .baseRefName 2>/dev/null) || continue
-            [[ "$BASE" == "$DEFAULT_BRANCH" ]] && continue
-            BODY=$(gh pr view "$pr" --repo "$REPO" --json body -q '.body // ""' 2>/dev/null) || continue
+            PR_JSON=$(gh pr view "$pr" --repo "$REPO" --json baseRefName,state,body) || continue
+            BASE=$(jq -r '.baseRefName' <<<"$PR_JSON")
+            [[ "$BASE" == "$DEFAULT_BRANCH" ]] && continue
+            # Only merged PRs shipped. Cheap guard: this field is already in hand.
+            [[ "$(jq -r '.state' <<<"$PR_JSON")" == "MERGED" ]] || continue
+            BODY=$(jq -r '.body // ""' <<<"$PR_JSON")
```

### A2.6 Move the step after the deploy trigger

**Why:** as placed, issues get closed with "Released in vX" before the prod deploy has even been
*triggered*, let alone succeeded — and the per-commit API loop can add minutes ahead of that trigger.
Bookkeeping should not delay or precede the deploy.

## A3. PR #77 — no changes requested

Merge as-is. The diagnosis, the input shape, and the default are all right; I verified the timeout
table in the description against `actions/vps-deploy-core/action.yml` and it matches exactly. Both
consumers (`areteos`, `bd-pulse`) are on `@v2`, neither passes `compose-build`, and no calling job
sets a `timeout-minutes` that would cap the new ceiling.

The two things it surfaces are separate work → issues B1 and B2.

---

# Bucket B — new issues

## B1. `aretecp/areteos` — dev and prod VPS deploys race one working tree

**Priority:** P1. This one can corrupt a prod deploy, and `aretecp/github-actions#77` makes it more
likely.

**Title:** `fix(deploy): dev and prod deploys race the same VPS working tree`

**Body:**

> `deploy-dev.yml` and `deploy-prod.yml` both deploy into `/home/${{ vars.VPS_USER }}/areteos`, but
> they use **different** concurrency groups (`deploy-dev` and `deploy-prod`). Nothing serialises them,
> so a dev deploy and a prod tag deploy can run at once and race `git checkout --force` in that one
> working tree. Worst case, prod containers get built from `develop` source.
>
> This isn't theoretical — the shared action already documents the shared directory. From
> `vps-deploy-core/action.yml`'s compose-up step:
>
> > There is intentionally NO `--remove-orphans`: on a shared VPS it would delete other stacks'
> > containers (Traefik, **or the prod project that shares this dir**).
>
> And `bd-pulse` already hit this and fixed it deliberately — from its `deploy-prod.yml`:
>
> > Shared with deploy-dev (#2299): both deploy from the SAME VPS checkout
> > (`/home/sglyon/bd-pulse`), so they must serialize — a concurrent dev + prod deploy would race
> > `git checkout --force` in that one working tree.
>
> areteos never got the same treatment.
>
> **Why now:** `aretecp/github-actions#77` raises the compose-up SSH timeout from 10m to 30m so a cold
> build isn't cut short. That is the right fix, but it triples the window during which a dev cold
> build is holding the tree.
>
> ### Option A — one concurrency group (matches bd-pulse)
>
> In both workflows:
>
> ```yaml
> concurrency:
>   group: areteos-vps-deploy
>   cancel-in-progress: false
> ```
>
> Cheap and proven. Cost: dev deploys queue behind prod, and with a 30m ceiling that can back up.
>
> ### Option B — give dev its own checkout (preferred)
>
> Set `repo-dir: /home/${{ vars.VPS_USER }}/areteos-dev` in `deploy-dev.yml`. Removes the race at the
> root rather than serialising around it, and dev keeps `cancel-in-progress: true`. `allow-clone: true`
> is already set on dev, so the VPS creates the directory itself on the next run.
>
> Check before doing this: any absolute bind-mount paths in `docker-compose.dev.yml`, and anything on
> the VPS that assumes the dev checkout lives at the prod path.
>
> ### Also
>
> `deploy-dev.yml` has `cancel-in-progress: true`. Cancelling the ssh-action does not stop the remote
> `docker compose build`, so a cancelled deploy keeps compiling on the VPS while its replacement starts
> a second build. Under Option B that's tolerable (separate trees); under Option A set it to `false`.

## B2. `aretecp/github-actions` — `pre-compose-up-script` has the same hardcoded 10m ceiling

**Priority:** P2. Same failure class `#77` just fixed, one step earlier.

**Title:** `fix(vps-deploy): expose a timeout for the pre-compose-up hook`

**Body:**

> `#77` added `compose-up-timeout` because the compose-up SSH step inherited `appleboy/ssh-action`'s
> 10m default and a cold build blew through it with a silent `Run Command Timeout`.
>
> `Run pre-compose-up script on VPS` in `actions/vps-deploy-core/action.yml` still has a hardcoded
> `command_timeout: 10m`, and that hook is how `rollback-vps-shared.yml` runs the DB restore:
>
> ```yaml
> pre-compose-up-script: ${{ steps.build-restore-script.outputs.restore-script }}
> ```
>
> A large restore hits the identical failure — no error, just a timeout partway through, on the one
> workflow you're running because something is already wrong. Rollback is the worst place for a
> confusing failure.
>
> **Fix:** add `pre-compose-up-timeout` (default `10m`, preserving current behaviour) wired the same
> way `#77` wired `compose-up-timeout`, and expose it through `deploy-vps-shared.yml` and
> `rollback-vps-shared.yml`.
>
> Low urgency today: `areteos` passes `db-type: none` and `bd-pulse`'s SQLite snapshot is small. It
> matters the first time a Postgres restore is wired up.

## B3. `aretecp/github-actions` — CI base images rollout gate

**Priority:** P1 as a gate, and it's the thing most likely to break CI fleet-wide if done out of
order.

**Title:** `chore(images): rollout gate for the CI base images`

**Body:**

> Tracking issue for landing `aretecp/github-actions#79` safely. **The consumer swap PRs must not
> merge before step 2.**
>
> `container.image` is pulled before any step runs. A private GHCR package fails the job at startup
> with a `denied` error and there is no in-workflow remedy: `container.credentials` becomes mandatory,
> and a consumer's own `GITHUB_TOKEN` cannot read a package owned by a different repo without an
> explicit grant. Both `README.md` and `images/README.md` already state "Public packages, so no
> `container.credentials` block is needed" — true only after step 2.
>
> - [ ] 1. `#79` merges with the `MIX_HOME`/`HEX_HOME` and smoke-test fixes (see review). Without them
>       step 4 breaks `areteos` and `arilearn-phx`.
> - [ ] 2. Set all six GHCR packages to **public**. Needs org-owner rights on packages — confirm who
>       has them before starting.
> - [ ] 3. Verify from a runner: `docker pull ghcr.io/aretecp/ci-elixir:1.18.4-otp-27` with no
>       credentials configured.
> - [ ] 4. Consumer PRs, one repo at a time, each swapping `container.image` and deleting its prereq
>       steps: `areteos` (ci.yml + desktop-ci.yml), `areteos-py` (backend + frontend),
>       `arilearn-phx` (**two** jobs — `Build & Test` and the doc-intel eval gate),
>       `beacon`.
> - [ ] 5. After each, confirm the deleted steps really were redundant — `mix deps.get`, `uv` resolution,
>       and `pkg-config` are the ones that fail late.
>
> `manifest.json` lists `arilearn-phx (ci.yml)` as one consumer; it has two container jobs, both of
> which install Hex + Rebar.

## B4. `aretecp/github-actions` — weekly image rebuild republishes moving tags unvalidated

**Priority:** P2, design decision. File after `#79` merges.

**Title:** `Weekly CI image rebuild republishes moving tags with no consumer validation`

**Body:**

> `ci-images.yml`'s Sunday 04:17 cron runs `docker build --pull`, refreshing the Debian base, and
> pushes the moving tags that every consumer pins. A base update can move chromium — which
> `areteos-py`'s PDF inertness test depends on — or gcc, under all consumers at once, with no diff and
> no PR. The dated tags exist for exactly this case but nothing pins them.
>
> Not a regression: chromium already drifts today (the apt cache key busts on the version change and
> the current candidate gets installed). The drift just relocates to a cron in a different repo, where
> it's less visible from the failing run.
>
> Options:
>
> - Scheduled runs push only `<tag>-<yyyymmdd>-<sha7>`, plus a bot PR advancing consumers. Drift
>   becomes reviewable; costs a PR a week.
> - Keep as-is and accept that Monday-morning breakage across the fleet is possible.
> - Have the weekly run trigger one consumer's CI against the new image before pushing the moving tag.
>
> Also, `<tag>-<yyyymmdd>-<sha7>` is described as immutable but is overwritten by a same-day rerun on
> the same SHA. Fine in practice for the weekly cadence; worth not calling it immutable.

## B5. `aretecp/areteos` — move `release.yml` to `release-shared.yml@v2`

**Priority:** P2, and it's a prerequisite for ever using `#78`'s feature. Spencer said he'd open this
separately, so this is only if you want it tracked.

**Title:** `chore(release): move release.yml from @v1 to @v2`

**Body:**

> `release.yml` pins `aretecp/github-actions/.github/workflows/release-shared.yml@v1`. `v1` is frozen
> at `5c93f3c1` (tip commit `7d245ad`, 2026-05-27) — releases now advance `v2`. So this repo gets no
> fixes to the shared release workflow, and `aretecp/github-actions#78`'s `close-released-issues`
> input will not exist at `@v1`.
>
> Verified safe: `release-shared.yml` is **byte-identical** at the `v1` tip and the `v2` tip
> (`git diff 7d245ad 11e24bb -- .github/workflows/release-shared.yml` is empty), so the move is a
> no-op for behaviour. Every other shared workflow in this repo is already on `@v2`.
>
> Also fix the now-false comment in the same file:
>
> > Bump the `@v1` ref there to pick up patch/minor fixes automatically.
>
> `v1` stopped moving when `v2` was cut. Consequence-free so far only because of the byte-identity
> above.

## B6 (optional). `aretecp/github-actions` — reduce the per-commit API cost of issue closing

**Priority:** P3. Only worth filing if A2.3 and A2.5 land and you still want the loop rewritten.

**Title:** `perf(release): batch the released-PR discovery into one GraphQL query`

**Body:**

> `close-released-issues` does one `gh api repos/.../commits/$sha/pulls` per commit in the released
> range, serially. `GITHUB_TOKEN` is capped at 1,000 requests/hour/repo, shared with whatever
> `semantic-release` just spent. The 1.43.0 promotion shipped 12 issues but the commit count behind it
> is much larger, and (before A2.3) exhausting the budget failed silently.
>
> Replace the loop with a single GraphQL query using aliased `object(oid:)` nodes and
> `associatedPullRequests { number baseRefName state body }` — which also removes the per-PR
> `gh pr view` entirely, since the body and base ref come back in the same response.

---

# Summary

| # | Where | What | Priority |
|---|---|---|---|
| A1.1 | PR #79 | `MIX_HOME`/`HEX_HOME` in both Elixir Dockerfiles | **Blocking** |
| A1.2 | PR #79 | Smoke test under `HOME=/github/home`; real rebar assertion | **Blocking** |
| A1.3 | PR #79 | Install the `stable` rust toolchain, not components for `1.97.1` | High |
| A1.4 | PR #79 | Concurrency key, `timeout-minutes`, arch-agnostic libpq, README tense | Low |
| A1.5 | PR #79 | Pre-merge: `git` on omarchy; one `workflow_dispatch` run | **Blocking** |
| A2.1 | PR #78 | Strip fences/blockquotes before matching | High |
| A2.2 | PR #78 | `off` / `report` / `close` mode | High |
| A2.3 | PR #78 | Summary on every exit path; stop swallowing `gh api` errors | High |
| A2.4 | PR #78 | `--match 'v[0-9]*'` on `git describe` | Medium |
| A2.5 | PR #78 | One `gh pr view`; add merged-state guard | Medium |
| A2.6 | PR #78 | Move step after the deploy trigger | Low |
| A3 | PR #77 | Nothing — approve and merge | — |
| B1 | areteos | Dev/prod deploys race one working tree | **P1** |
| B2 | github-actions | `pre-compose-up-timeout` | P2 |
| B3 | github-actions | Image rollout gate (packages public before consumers) | **P1** |
| B4 | github-actions | Weekly rebuild republishes moving tags unvalidated | P2 |
| B5 | areteos | `release-shared.yml@v1` → `@v2` | P2 |
| B6 | github-actions | Batch the PR discovery into one GraphQL query | P3 |

Say which of B1–B6 to create and whether to post A1/A2 as PR review comments, and I'll do it.
