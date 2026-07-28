# Plan: Claude Issue Triage — zero-config app shims + fleet migration

**Status**: Draft
**Created**: 2026-07-28
**Last updated**: 2026-07-28

---

## Context

`claude-issue-triage.yml@v2` is a reusable workflow, but consumers still hand it 4–6 lines of
Infisical config that is **identical in every repo**. Worse, only 2 of 6 repos with triage
actually call the shared workflow — the other 4 still carry ~130-line inline copies that have
silently drifted.

Goal: an app-side shim with **no `with:` block at all**, and every app on it.

### Current state (measured)

| Repo | Shim? | Lines | Auth | Notes |
|---|---|---|---|---|
| `areteos` | shim `@v1` | 31 | OIDC | works; stale major tag |
| `beacon` | shim `@v2` | 38 | OIDC | works; no priority labels in repo |
| `arilearn-phx` | inline | 131 | `secrets.ANTHROPIC_API_KEY` | **local prompt is ahead of shared** |
| `bd-pulse` | inline | 144 | OIDC (in-line load step) | |
| `contact-intelligence` | inline | 132 | `secrets.ANTHROPIC_API_KEY` | **currently broken** — checks out `ref: main`, repo has no `main` (default is `master`) |
| `infisical` | inline | 132 | `secrets.ANTHROPIC_API_KEY` | **out of scope — leave as-is**, see below |
| `areteos-py` | none | — | — | WIP branch `ci/claude-issue-triage`, no PR |
| `ari-website` | none | — | — | **open PR #31** — shim `@v1`, path `/ari-website` (folder doesn't exist) |

### Why the inputs exist

`ANTHROPIC_API_KEY` is stored **per app** in `arete-internal`. Folder-per-repo holds for
`/areteos`, `/areteos-py`, `/arilearn-phx`, `/bd-pulse`, `/beacon` — but **not** for
`contact-intelligence` or `ari-website`, both of which are being onboarded.
There are ~12 `ANTHROPIC_API_KEY` entries across folders with at least 8 distinct key values,
plus `anthropic-api-key` and `ARILEARN_ANTHROPIC_API_KEY` variants.

**Decision (Dominick, 2026-07-28)**: apps keep their own keys for app-runtime reasons. CI gets
its own folder: `arete-internal/<env>/github-actions`. Shared CI workflows default there, so no
app passes Infisical config at all.

### `aretecp/infisical` is excluded (decision, 2026-07-28)

That repo is the **self-hosted Infisical deployment** — the Docker Compose stack that serves the
very API this workflow authenticates against. Migrating it would be a bootstrap dependency: issues
get filed there when Infisical is *down*, which is exactly when the triage job can't fetch its own
key. Today it uses a GH repo secret and has no Infisical dependency; the migration would introduce
one.

It's also inert: `open_issues_count: 0`, no issues ever filed, no triage run ever recorded. (There
are no *repo-level* secrets either, but an org-level `ANTHROPIC_API_KEY` scoped to the repo would
still satisfy it — unverifiable without `admin:org`, so treat "it would fail" as unknown, not
established.)

**Action**: none. Leave `aretecp/infisical/.github/workflows/claude-issues.yml` in place and
untouched — it's an inline copy that no longer matters because nothing triggers it. Deleting the
132 dead lines is optional tidying, not a prerequisite; a one-line PR whenever it's wanted.

If triage is ever genuinely wanted there, use the forwarded-secret path (still supported by the
shared workflow) so it stays independent of the service this repo deploys.

Scope is therefore **7 repos** for migration, with infisical left as-is.

---

## Target shim (all repos, 15 lines)

```yaml
name: Claude Issue Triage

on:
  issues:
    types: [opened]
  issue_comment:
    types: [created]

# Reusable workflows can only USE permissions the caller grants.
permissions:
  contents: read
  issues: write
  id-token: write

jobs:
  triage:
    uses: aretecp/github-actions/.github/workflows/claude-issue-triage.yml@v2
```

Only `beacon` keeps one input (`checkout-ref: develop` — it deliberately triages dev code while
its default branch is `main`). Everything else is irreducible GHA structure: triggers must live in
the caller, and a caller's `permissions` grant is the ceiling for the reusable job.

---

## Design

### Shared workflow — coalesce defaults at the use site

`workflow_call` input defaults can't hold expressions, so default inside the job:

```yaml
- name: Load ANTHROPIC_API_KEY from Infisical (OIDC)
  if: ${{ (inputs.infisical-identity-id || vars.INFISICAL_OIDC_IDENTITY_ID) != '' }}
  uses: aretecp/github-actions/actions/load-infisical-secrets@v2
  with:
    method: oidc
    identity-id:  ${{ inputs.infisical-identity-id  || vars.INFISICAL_OIDC_IDENTITY_ID }}
    project-slug: ${{ inputs.infisical-project-slug || vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
    environment:  ${{ inputs.infisical-env          || 'prod' }}
    path:         ${{ inputs.infisical-path         || '/github-actions' }}
```

Also:
- `checkout-ref` default `main` → `${{ github.event.repository.default_branch }}`
  (fixes `contact-intelligence` incidentally: `master`, not `main`)
- `environment` default `production` → `''`. With OIDC the job needs no env-scoped secrets, and
  a default of `production` means triage runs inside a deployment environment — if anyone ever
  adds required reviewers there, triage silently blocks pending approval. `ari-website` has no
  environments at all.
- All four `infisical-*` inputs stay as **optional overrides** — the forwarded-secret path keeps
  working for any caller that hasn't migrated.

### System prompt — port arilearn-phx's improvements first

`arilearn-phx/.claude/prompts/ci-triage.md` is **8 lines ahead** of the shared prompt. Migrating
that repo without porting these is a regression:

1. **Idempotent labelling** — strip conflicting priority/type labels before adding, so re-runs
   and human-preset labels don't leave duplicates
2. **GitHub issue *type*** (distinct from the type label) via the GraphQL `updateIssue` mutation,
   using `github_issue_types` IDs from CLAUDE.md Project Config

Both get ported with graceful degradation, because most repos can't satisfy them:
- priority labels `P1-critical`…`P4-low` are **missing** in `beacon`, `ari-website`;
  `areteos-py` uses `priority-high/medium/low` instead
- only `arilearn-phx` and `areteos` have a `## Project Config` block in CLAUDE.md at all
- observed in beacon run `30037436400`: *"Priority labels aren't defined in this repo"*

So: prompt instructs Claude to check what exists and skip cleanly, never to hard-fail. Label
backfill (Phase 6) then makes the happy path real.

---

## Phases

### Phase 0 — spikes ✅ ALL PASS (2026-07-28, beacon run `30369406219`)

Run as a temporary push-triggered probe rather than a real issue, so it cost one 9-second run and
no issue spam. Both probe files and both spike branches have been deleted.

| Spike | Result | Evidence |
|---|---|---|
| S1 — `vars.*` resolves from caller | **PASS** | `identity-id length: 36`, `internal project slug: 'arete-internal'` — caller org vars visible inside the reusable workflow |
| S2 — `environment: ''` legal | **PASS** | job started normally with an empty environment name |
| S3 — new Infisical CI folder + OIDC grant | **PASS** | `ANTHROPIC_API_KEY` loaded from `arete-internal/prod/github-actions`, length 108 |

**Consequence**: no fallback needed. Zero-input shim confirmed at **15 lines**, and Phase 1 is
validated end-to-end rather than by inspection.

<details><summary>Original spike definitions (kept for the record)</summary>

Run in **`beacon`** — already OIDC-proven and low traffic, so it isolates these two variables from
the OIDC-grant question in Phase 1.

- [ ] **S1: does `vars.*` resolve to the *caller's* repo inside a reusable workflow?** The whole
      zero-input design depends on it. Secrets need explicit passing; vars are believed to resolve
      against the caller, but this is worth one run rather than my word.
      *Fallback if no*: `infisical-identity-id` stays a required input, literals replace the other
      three, shim lands at ~18 lines instead of 15.
- [ ] **S2: is `environment: ''` legal?** Confirm the job starts with no environment.
      *Fallback if no*: keep `environment` default `production` and create a `production`
      environment in `ari-website`.
- [ ] Record both outcomes in this doc before Phase 2.

</details>

### Phase 1 — Infisical `/github-actions` folder ✅ (Dominick, 2026-07-28)

- [x] Create folder `github-actions` in `arete-internal`, envs `dev` + `prod`
- [x] Generate a **new, dedicated** Anthropic API key for CI (not a copy of an app key — separate
      key means separate spend attribution and independent revocation). Set as
      `ANTHROPIC_API_KEY`. *Confirmed present in `prod` by spike S3.*
- [x] Grant the OIDC machine identity read on `arete-internal` `/github-actions`
      *Confirmed by spike S3.*
- [ ] **Verify OIDC trust policy + org-var visibility covers the new repos.**
      `contact-intelligence` and `ari-website` have never used
      `vars.INFISICAL_OIDC_IDENTITY_ID` in any workflow, so neither the identity's subject filter
      nor the org variable's selected-repos list is confirmed for them. (I can't read org vars —
      `gh api /orgs/aretecp/actions/variables/...` returns 403 without `admin:org`; run
      `gh auth refresh -h github.com -s admin:org` or check in the UI.)
- [ ] Update `docs/runbooks/infisical-machine-identity.md` — it documents only Universal Auth
      today; add the OIDC identity and the `/github-actions` CI folder convention

### Phase 2 — slim the shared workflow ✅ PR #64 open (awaiting human merge)

- [x] Port the two arilearn-phx improvements into `.claude/prompts/ci-triage.md`, with graceful
      degradation when priority labels / `github_issue_types` are absent
      — **improved on arilearn**: issue-type IDs are resolved at run time via a repo-scoped
      GraphQL query (they're org-level; confirmed identical to arilearn's hardcoded IDs), so no
      per-repo CLAUDE.md `github_issue_types` block is needed anywhere
- [x] Apply the coalesced defaults, `checkout-ref` → `default_branch`, `environment` → `''`
- [x] Rewrite the header comment block: document that the OIDC path now needs **zero inputs**
      (includes a copy-pasteable 15-line shim)
- [x] `actionlint` — clean; 2 pre-existing SC2086 infos remain on untouched lines
- [x] README: triage row `v1` → `v2`, plus a "Zero-config consumer shim" section
- [x] **Bonus bug found**: `shared-ref` defaulted to `v1`, so consumers pinned `@v2` ran v2 logic
      against a frozen v1 prompt. Now `v2`, with a note that it must track the major.
- [x] Added a fail-fast auth check — a missing org-var grant now says what to fix instead of dying
      in an opaque Claude auth error
- [ ] **BLOCKED ON MERGE**: `v2.5.0` + `v2` move happens automatically via `release.yml` on push
      to `main` (conventional `feat:` → minor bump). Nothing to do by hand.

### Phase 3 — canary

- [ ] `areteos` → target shim, `@v1` → `@v2`, drop `with:` entirely
- [ ] `beacon` → drop `with:` except `checkout-ref: develop`
- [ ] File a real test issue in each; confirm the Infisical load, the triage comment, and labels
- [ ] Do not proceed to Phase 4 until both are green

### Phase 4 — migrate the 3 inline copies

One PR per repo, each deleting ~130 lines:

- [ ] `bd-pulse` (144 → 15)
- [ ] `arilearn-phx` (131 → 15) — verify the ported prompt still sets issue type, since this repo
      is the only one that already had it working
- [ ] `contact-intelligence` (132 → 15) — also fixes the broken `ref: main`; drop the now-unused
      `ANTHROPIC_API_KEY` repo secret
- [ ] `infisical` — **no change.** Excluded by design (see Context); its inline copy stays as-is
      because nothing triggers it.
- [ ] Per repo: `grep -rn "ci-triage.md"` before deleting the local
      `.claude/prompts/ci-triage.md` — delete only if the workflow was its sole consumer

### Phase 5 — onboard the two new repos

- [ ] `areteos-py` — reuse existing branch `ci/claude-issue-triage`, replace its `@v1` + 4-input
      shim with the target form, open a PR
- [ ] `ari-website` — **supersede open PR #31**: update that branch rather than opening a second.
      Rename `claude-issue-triage.yml` → `claude-issues.yml` to match fleet convention, drop the
      `/ari-website` path (folder doesn't exist — as written that PR would fail on merge)

### Phase 6 — labels, docs, memory

- [x] Backfill the standard label set where missing: `P1-critical`, `P2-high`, `P3-medium`,
      `P4-low` created in `beacon`, `ari-website`, `areteos-py` (2026-07-28)
      (`bug` / `enhancement` / `documentation` already exist everywhere by default)
- [ ] **NEEDS A DECISION — `areteos-py` now has two parallel priority schemes.** Its native
      `priority-high` / `priority-medium` / `priority-low` are heavily used: 100+, 100+, and 44
      issues respectively (counts capped by the query limit, so the real totals are higher).
      Remapping 244+ issues is not a safe unilateral call, and the mapping is ambiguous
      (`priority-high` → `P1-critical` or `P2-high`?). Left untouched for now, so new issues get
      `P1`–`P4` while historical ones keep `priority-*`. Options:
      (a) leave both, accept the split at this date; (b) bulk-relabel history to `P1`–`P4`;
      (c) drop `P1`–`P4` from this repo and teach the prompt the `priority-*` scheme.
- [ ] Add a `## Project Config` block (with `base_branch`) to the 5 repos missing one, so the
      prompt stops improvising: `bd-pulse`, `contact-intelligence`, `beacon`, `areteos-py`,
      `ari-website`
- [ ] README: add `areteos-py` + `ari-website` to the consumer list
- [ ] Session memory: record the `/github-actions` Infisical CI-folder convention

---

## Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | `vars.*` doesn't resolve from caller → design collapses | Phase 0 S1 before any migration; documented fallback |
| R2 | `environment: ''` rejected by GHA | Phase 0 S2; fallback keeps `production` + creates the env in ari-website |
| R3 | OIDC not trusted for `contact-intelligence` / `ari-website` (never used it) → triage fails on first run | Phase 1 verification gate; those repos land last |
| R7 | A shared CI workflow that depends on Infisical can't triage Infisical itself | `aretecp/infisical` excluded by design; if ever wanted, use the forwarded-secret path |
| R4 | Migrating arilearn-phx loses its prompt improvements | Port them into shared **first** (Phase 2), migrate that repo **after** the canary |
| R5 | Label/issue-type steps fail where labels are absent | Prompt degrades gracefully; Phase 6 backfills |
| R6 | New CI key raises Anthropic spend on a separate line item | Intentional — that's the attribution benefit; watch first week |

## Rollback

Every phase is independently revertable. Shared-workflow regressions: move the `v2` tag back to
`v2.4.0`; all consumers pin `@v2`, so one tag move restores the fleet. Per-app shims: revert the
PR (the inline copies stay in git history).

## Out of scope

- **`pr-to-main-hooks.yml` has the same disease, worse** — 6 Infisical inputs (app path for
  `ANTHROPIC_API_KEY`, shared path for the Teams webhook). Putting both secrets in
  `/github-actions` would collapse it to zero inputs too. Same fix, separate change — file an
  issue after Phase 3 proves the pattern.
- **Consolidating the ~12 per-app `ANTHROPIC_API_KEY` copies** — explicitly declined; apps need
  their own keys. The naming drift (`anthropic-api-key`, `ARILEARN_ANTHROPIC_API_KEY`) is worth a
  separate cleanup ticket.
- Any change to `/work-issue` or the local `.claude/` command set.
