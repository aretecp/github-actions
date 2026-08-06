# Long-term fixes — root causes behind PRs #77 / #78 / #79

The tactical fixes in `pr-77-78-79-fixes.md` are patches. Several of the findings are the same root
cause wearing different hats. Ranked by leverage.

Facts verified while writing this:

- `aretecp/github-actions` is **PUBLIC**; default branch `main`
- `areteos` default `main`, `bd-pulse` default `main`, **`arilearn-phx` default `develop`**
- Issue #4 ("Smoke-test workflow for load-infisical-secrets") exists and is **CLOSED** —
  `RELEASING.md` still points at it as the way to re-enable a validation gate
- `smoke-teams-notify.yml` exists and declares itself the repo's smoke pattern
- `vps-deploy-core` **already** runs `docker compose pull` when `compose-build != true`

---

## 1. Build images in CI, not on the VPS

**Root cause it kills:** the deploy compiles application source on the production host, over an SSH
session, in a mutable shared checkout. Every symptom in PR #77 follows from that.

**What becomes unnecessary:**

- PR #77's timeout entirely — nothing long-running happens over SSH anymore
- Issue B2 (`pre-compose-up-timeout`) — near-pointless once builds move
- Issue B1's race at the root — no source tree on the VPS to `git checkout --force` into
- "Rerunning is not a reliable remedy" (Docker only commits a layer when its `RUN` completes) — CI
  builds have a proper layer cache and retry story
- Rollback becomes repinning an image tag instead of re-checking-out a tag and rebuilding it

**Most of the plumbing already exists.** `vps-deploy-core`'s compose-up step:

```bash
if [[ "$COMPOSE_BUILD" != "true" ]]; then
  # Not building from source — pull pre-built images first.
  docker compose --env-file "$ENV_FILE_NAME" -f "$COMPOSE_FILE" pull
fi
```

So the shared action already supports the pull path; no consumer currently uses it. And PR #79 just
established the GHCR build/login/push pattern on the self-hosted runners — the same muscle.

**Cost:** app-side, per repo. A CI job that builds and pushes on tag, compose files switched from
`build:` to `image: ghcr.io/aretecp/<app>:<version>`, registry auth on the VPS, and build minutes
moving to omarchy/kenya.

**Risk:** the deploy gains a runtime dependency on GHCR reachability from the VPS — needs a pull
retry. Image pull time over the VPS link replaces build time, which is usually a large net win but
should be measured for the Elixir release images.

**Decision this forces:** if this is on the roadmap at all, stop investing in VPS-build timeouts.
Merge #77 because it's cheap and correct today, but don't build B2.

---

## 2. Move `concurrency` into the reusable deploy workflows

**Root cause it kills:** every consumer hand-writes its own concurrency group, so the invariant
"only one deploy may touch a given VPS directory at a time" is re-derived per repo and gets got wrong.
`areteos` has it wrong right now. `bd-pulse` has it right only because it was bitten (its comment
cites #2299). Nothing stops the next repo repeating it.

**Fix** — inside `deploy-vps-shared.yml` and `rollback-vps-shared.yml`, at the job level:

```yaml
jobs:
  deploy:
    concurrency:
      # The invariant is a property of the TARGET, not of the calling workflow:
      # one deploy at a time per VPS directory. Derived here so no consumer can
      # get it wrong — this serialises dev+prod, deploy+rollback, across repos.
      group: vps-${{ inputs.vps-user }}-${{ inputs.repo-dir }}
      cancel-in-progress: false
```

Serialises every deploy targeting the same directory automatically. **Zero consumer changes.**
Callers keep their own workflow-level groups for their own reasons; both apply.

**Cost:** ~30 minutes. Best cost/benefit item on this list.

**Caveats:**
- Verify `inputs` is available in a called workflow's job-level `concurrency` before relying on it —
  cheap to test, and load-bearing here.
- With `cancel-in-progress: false`, GitHub keeps only the most recent *pending* run per group and
  cancels older pending ones. For deploys that's the behaviour you want.

Worth doing **even if #1 lands** — you still want `compose up` against one directory serialised.

---

## 3. Make `develop` the default branch on develop-flow repos

> **Weakened by the areteos finding (2026-08-06).** `pr-to-main-hooks.yml` already writes `Closes #N`
> footers into the promotion PR, whose base is `main` — the default branch for areteos and bd-pulse —
> so GitHub's native closing already fires there. Its *discovery* is broken (harvests bare `#N` from
> commit messages, not from feature-PR bodies), and fixing that gets close-at-release semantics,
> native GitHub closing, and a human review gate without touching any default branch.
>
> So the issue-closing motivation for this item is largely gone. What remains is the `gh pr create`
> argument below, which is real but much smaller. Treat this as optional now, not as the fix for #78.

**Root cause it kills:** `develop → main` fights GitHub's model. Closing keywords,
`closingIssuesReferences`, the linked-issues sidebar, and Dependabot all key on the *default* branch.
PR #78 is a bash reimplementation of GitHub's closing-keyword parser — a parser that isn't specified,
which is why the regex review found fenced-code and negated-prose matches. That work is unwinnable in
the long run.

**The org is already inconsistent, and the repo doing it the recommended way doesn't have the problem:**

| repo | default | affected by #78's problem? |
|---|---|---|
| `arilearn-phx` | `develop` | **No** — PRs target the default branch, so `Closes #N` fires |
| `areteos` | `main` | Yes — this is the repo that had 12 issues to close by hand |
| `bd-pulse` | `main` | Yes |

**Secondary benefit that matters more than it looks.** `gh pr create` and the GitHub UI default to the
default branch. Today the `feature → develop → main` rule is enforced by a guard hook catching
mistakes after the fact — and the rule exists because a fix once got merged straight to `main` and
auto-deployed to prod. With `develop` as default, the tooling default *is* the policy, and that
failure mode stops being reachable by accident.

`main` stays the release and deploy trigger — `on: push: branches: [main]` is unaffected by which
branch is "default."

**The decision that gates this:** *when should an issue close — when the work merges, or when it
ships?*

- **At merge** → make `develop` default, and PR #78 should not merge at all.
- **At release** → keep something like #78, but not prose parsing. Deterministic version: label the
  issue `pending-release` at merge time (where GitHub's own linked-issue data is available once
  `develop` is default), and have the release workflow close everything carrying that label. One
  place, no regex, auditable.

**My read:** merge-time closing is right for almost every issue, and the generated release notes
already record what shipped. I'd take `develop`-as-default and drop #78. **Worth asking Spencer this
before he spends more time on the regex** — the shape of the answer decides whether that PR has a
future.

---

## 4. Forbid `$HOME` writes in CI images, enforced at build time

**Root cause it kills:** the MIX_HOME bug isn't about Mix. It's that an image's build-time
environment (`HOME=/root`) differs from its runtime environment (`HOME=/github/home`) and nothing
checks. The next tool anyone bakes has the same trap: npm/`.npmrc`, bun, the pnpm store, cargo
without the official image's env, pip cache, gcloud, `.gitconfig`.

**Fix** — a final layer in each Dockerfile, or one shared check in `ci-images.yml`:

```dockerfile
# A GitHub Actions container job runs with HOME=/github/home (an empty per-job
# mount), so anything this build wrote under /root is invisible at runtime. Fail
# the build rather than ship an image whose tools silently disappear.
RUN test -z "$(find /root -mindepth 1 -print -quit)" || { \
      echo "ERROR: build wrote under /root — use a system path (MIX_HOME, UV_INSTALL_DIR, ...)"; \
      find /root -mindepth 1 -maxdepth 3; exit 1; }
```

Catches the entire class at build time, for every image added later, with no per-tool knowledge
required. Pair it with the smoke-test fix (`-e HOME=/github/home --tmpfs /github/home`), which catches
the same class from the runtime side.

**Cost:** ~15 minutes. Highest ratio of future-bugs-prevented to effort on this list.

---

## 5. A canary consumer repo — the missing integration environment

**Root cause it kills:** all three PRs say some version of *"not exercised end to end."* That is not
a review failure; it's an infrastructure gap. This repo ships workflows that only run in *other*
repos, and there is nowhere to run them. `RELEASING.md`'s validation gate is literally "a real
consumer has exercised every changed action" — production is the test environment.

Issue #4 designed the smoke gate and was closed on "the public-repo logging tradeoff." That tradeoff
is real: `github-actions` is **PUBLIC**, so exercising live Infisical/VPS/GHCR credentials inside it
leaks into public logs.

**Fix:** `aretecp/github-actions-canary`, **private** — a throwaway app with a small real compose
stack on the VPS and its own scoped Infisical folder. It pins `@main`. A scheduled + pre-release run
exercises the whole chain: deploy → healthcheck → rollback → release → issue close. Private repo
means real secrets and real logs with no exposure, which is exactly what killed #4.

This is what would have caught: #79's workflow never having run, #78's release path, and a
#77-class cold-build timeout (a canary can deliberately bust its dependency layer on a schedule).

**Cost:** real — a day or two plus a VPS slot. It is the only item that converts "reasoned about
carefully" into "verified."

**Cheaper first step, worth doing regardless:** extend `smoke-teams-notify.yml` — which the repo
already declares as *the* pattern, and `CONTRIBUTING.md` step 5 tells contributors to copy — to the
paths that need no secrets:

- #78's keyword extraction and summary rendering, against fixture PR bodies including the fenced-code
  and negated-prose cases
- #79's image contract, which the A1.2 smoke fix already covers

That's unit-level coverage this week without waiting on the canary.

---

## 6. Scheduled consumer-pin audit

**Root cause it kills:** nobody can see what consumers are actually pinned to. `areteos` sat on a
frozen `@v1` for over two months while its own comment claimed *"Bump the `@v1` ref there to pick up
patch/minor fixes automatically."* Nothing noticed, and nothing would have. The same blindness will
hide PR #79's rollout half-states — packages still private, consumers still installing prereqs.

**Fix:** reuse `entra-secret-detector.yml`'s shape exactly — scheduled, read-only, reports findings
in the summary, silent when clean. Enumerate org repos, grep `uses: aretecp/github-actions/...@REF`,
flag any ref that is not the current major.

**Cost:** 1–2 hours, and it extends a proven in-repo pattern rather than inventing one.

---

## Sequencing

| When | Item | Effort |
|---|---|---|
| This week | **2** (concurrency in the shared workflow) | ~30 min |
| This week | **4** (`$HOME` build-time guard) | ~15 min |
| This week | **6** (consumer-pin audit) | 1–2 h |
| This week | **5b** (extend the smoke pattern to no-secret paths) | 2–3 h |
| Decision, not work | **3** (`develop` as default) — ask before more #78 effort | — |
| Quarter-scale | **1** (build in CI, deploy by pull) | days, app-side |
| Quarter-scale | **5a** (private canary repo) | 1–2 days |

## What this changes about the three PRs

- **#77** — merge as-is. But if item 1 is on the roadmap, don't build B2.
- **#78** — **hold on the decision in item 3, not just on the code.** If `develop`-as-default is
  acceptable, this PR shouldn't merge. Ask before more regex work.
- **#79** — merge with the blocking fixes. It's also the enabler for item 1, which is a good reason to
  land it properly rather than quickly.
