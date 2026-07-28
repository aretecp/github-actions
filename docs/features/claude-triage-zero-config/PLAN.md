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

Everything left is irreducible GHA structure: triggers must live in the caller, and a caller's
`permissions` grant is the ceiling for the reusable job.

**Decision (Dominick, 2026-07-28): triage analyzes the trunk branch, not develop.** PRs flow
through develop, but the code Claude reads when triaging is trunk. Since the shared workflow
defaults `checkout-ref` to the caller's default branch, that means **zero inputs in 6 of 7 repos**:

| Repo | Default branch | Input needed |
|---|---|---|
| `areteos`, `beacon`, `bd-pulse`, `areteos-py`, `ari-website` | `main` | none |
| `contact-intelligence` | `master` (no `main` exists — master *is* trunk) | none |
| `arilearn-phx` | `develop` (but `main` exists) | `checkout-ref: main` |

This reversed an earlier read of mine: I first shipped `checkout-ref: develop` everywhere on the
assumption that "everything goes through develop" applied to the analysis ref too. It doesn't —
that convention is about merge flow.

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
- [x] **R3 diagnosed and fixed (2026-07-28).** Probed both never-OIDC repos directly
      (`contact-intelligence` run `30372414296`, `ari-website` run `30372418529`). Both failed with
      `identity-id length: 0`.

      **Root cause — not org-level visibility.** Areté does not use org-level Actions variables at
      all; every repo carries its own **repo-level** copies. `gh variable list` across the fleet
      showed the real state: `contact-intelligence` had the three `INFISICAL_*_PROJECT_SLUG` vars
      but was missing `INFISICAL_OIDC_IDENTITY_ID`; `ari-website` had none at all. That exactly
      explains the asymmetry in the probe output (contact-intelligence resolved the slug but not
      the identity).

      My first diagnosis — "add these repos to the org variable's selected-repositories list" —
      was wrong, and the `admin:org` 403 masked it: I couldn't list org variables, so I assumed
      that's where they lived. Corrected by Dominick.

      **Fix applied**: copied `INFISICAL_OIDC_IDENTITY_ID` into `contact-intelligence`, and the
      identity plus all three project-slug vars into `ari-website`, matching fleet convention. The
      identity UUID is identical across all five working repos.

      Unaffected: `bd-pulse`, `arilearn-phx`, `areteos-py` already carry the repo-level vars.

      **Follow-up worth considering**: nothing enforces that a new repo gets these four variables,
      and the failure mode is a workflow that silently resolves an empty identity. A bootstrap
      script or a checklist entry in the machine-identity runbook would prevent the next repeat.

- [ ] Original wording of this check:
      `contact-intelligence` and `ari-website` have never used
      `vars.INFISICAL_OIDC_IDENTITY_ID` in any workflow, so neither the identity's subject filter
      nor the org variable's selected-repos list is confirmed for them. (I can't read org vars —
      `gh api /orgs/aretecp/actions/variables/...` returns 403 without `admin:org`; run
      `gh auth refresh -h github.com -s admin:org` or check in the UI.)
- [ ] Update `docs/runbooks/infisical-machine-identity.md` — it documents only Universal Auth
      today; add the OIDC identity and the `/github-actions` CI folder convention

### Phase 2 — slim the shared workflow

- [ ] Port the two arilearn-phx improvements into `.claude/prompts/ci-triage.md`, with graceful
      degradation when priority labels / `github_issue_types` are absent
- [ ] Apply the coalesced defaults, `checkout-ref` → `default_branch`, `environment` → `''`
- [ ] Rewrite the header comment block: document that the OIDC path now needs **zero inputs**
- [ ] `actionlint`
- [ ] Cut `v2.5.0`, move the `v2` tag
- [ ] README: triage row says `v1` → change to `v2`

### Phases 3–5 — all 7 shim PRs open against `develop` (awaiting human merge)

Canary sequencing was dropped on request: all seven went out together rather than 2-then-5.
All target `develop` (Areté repos merge through develop first — the earlier PRs targeting `main`
were closed).

| Repo | PR | Before → after |
|---|---|---|
| `areteos` | aretecp/areteos#1449 | 31 → 13, off stale `@v1` |
| `beacon` | aretecp/beacon#129 | 38 → 13 |
| `bd-pulse` | aretecp/bd-pulse#2639 | 144 → 13 |
| `arilearn-phx` | aretecp/arilearn-phx#1214 | 131 → 15 (only repo needing an input) |
| `contact-intelligence` | aretecp/contact-intelligence#76 | 132 → 13, fixes broken checkout |
| `areteos-py` | aretecp/areteos-py#846 | `@v1` 4-input → 13 |
| `ari-website` | aretecp/ari-website#32 | net-new, 13 |

Closed as superseded: areteos#1448, beacon#128 (wrong base), ari-website#31 (stale `@v1`, pointed
at a nonexistent `/ari-website` Infisical folder).

- [ ] ⚠️ **Still never exercised against a real issue.** The canary step was skipped when the PRs
      were retargeted. `issues`-triggered workflows only run from the default branch, so this
      cannot be tested until at least one shim merges. Merge one repo, file a test issue, confirm
      the comment + labels + issue type, then merge the rest.

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

- [ ] Backfill the standard label set where missing: `P1-critical`, `P2-high`, `P3-medium`,
      `P4-low` in `beacon`, `ari-website`, `areteos-py`
      (`bug` / `enhancement` / `documentation` already exist everywhere by default)
- [ ] `areteos-py`: decide whether `priority-high/medium/low` gets aliased or replaced — don't
      leave two parallel priority schemes
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
