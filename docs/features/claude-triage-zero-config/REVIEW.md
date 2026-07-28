# Review handoff — Claude issue triage zero-config

**Date**: 2026-07-28
**Plan**: [`PLAN.md`](PLAN.md)

8 PRs. One shared-repo change is already merged (#64, released as `v2.5.0`); the rest are app shims
plus a docs PR.

## Suggested review order

Review the shared side first — every app PR is just a 13-line file that depends on it.

| # | PR | Repo | Diff | What to look at |
|---|---|---|---|---|
| 1 | [github-actions#65](https://github.com/aretecp/github-actions/pull/65) | github-actions | +60/−22 | Docs only. The plan doc, including two corrections I had to make mid-flight. |
| 2 | [areteos#1449](https://github.com/aretecp/areteos/pull/1449) | areteos | +11/−14 | Representative shim. If this one reads right, 5 others are byte-identical. |
| 3 | [beacon#129](https://github.com/aretecp/beacon/pull/129) | beacon | +9/−19 | Same file. Behavior change: used to analyze `develop`, now `main`. |
| 4 | [bd-pulse#2639](https://github.com/aretecp/bd-pulse/pull/2639) | bd-pulse | +12/−128 | Deletes the largest inline copy. |
| 5 | [arilearn-phx#1214](https://github.com/aretecp/arilearn-phx/pull/1214) | arilearn-phx | +12/−115 | **The one that deserves real scrutiny** — see below. |
| 6 | [contact-intelligence#76](https://github.com/aretecp/contact-intelligence/pull/76) | contact-intelligence | +12/−116 | Fixes triage that never worked here. Red checks are not mine — see below. |
| 7 | [areteos-py#846](https://github.com/aretecp/areteos-py/pull/846) | areteos-py | +11/−14 | Replaces a `@v1` 4-input shim. |
| 8 | [ari-website#32](https://github.com/aretecp/ari-website/pull/32) | ari-website | +28/−0 | Net-new. Supersedes the closed #31. |

Net: **−424 lines** of duplicated workflow across the fleet.

## The one PR worth real attention

**arilearn-phx#1214.** Its local system prompt had drifted *ahead* of the shared one — it had
idempotent label handling and GitHub issue-type support that no other repo had. Migrating it
naively would have silently regressed that repo.

I ported both into the shared prompt first, and changed how issue types resolve: a run-time
repo-scoped GraphQL query instead of hardcoded `github_issue_types` IDs in each repo's CLAUDE.md.
I verified the org-level IDs are identical to the ones hardcoded in arilearn's CLAUDE.md, so
behavior should be unchanged there — **that equivalence is the thing worth double-checking**, since
it's the one place this migration could quietly lose something.

It's also the only shim that still passes an input (`checkout-ref: main`), because it's the only
repo whose default branch is `develop`.

## Red checks — both pre-existing, neither caused by these PRs

Every one of these PRs changes exactly one file: `.github/workflows/claude-issues.yml`.

- **contact-intelligence#76** — `Lint Backend` / `Test Backend` fail on `ruff` violations in
  backend Python (G201, f-string conversions). Cause: that repo's `ci.yml` only triggers on
  `pull_request`, and its last CI run was **2026-05-19**. Develop has ~2 months of un-gated lint
  debt, and this PR is simply the first thing to run CI since. Worth its own issue.
- **areteos#1449** — `Build and Test` failed with
  `The database for Areteos.Repo couldn't be created: command timed out`. Infrastructure flake;
  re-run to confirm.

## What is NOT verified

**None of this has been exercised against a real issue.** The canary step was dropped when the PRs
were retargeted to `develop`, and `issues`-triggered workflows only run from a repo's default
branch — so it cannot be tested until at least one shim merges.

**Recommended**: merge one repo (areteos or beacon), file a throwaway issue there, confirm the
triage comment, labels, and issue type, then merge the remaining six.

What *has* been verified end-to-end against real Infisical, before any app PR was opened:

| Check | Evidence |
|---|---|
| `vars.*` resolve to the caller inside a reusable workflow | beacon run `30369406219` |
| `environment: ''` is legal | same run |
| Shared CI key readable at `arete-internal/prod/github-actions` | same run, key length 108 |
| contact-intelligence can authenticate via OIDC | run `30372414296`, `OIDC PASS` |
| ari-website can authenticate via OIDC | run `30372418529`, `OIDC PASS` |

## Two things I got wrong during this work

Flagging these because they're the kind of thing a reviewer should know I touched.

1. **`github.job_workflow_sha` does not exist.** I wrote a default that relied on it to keep the
   prompt pinned to the workflow's own commit. `actionlint` flagged it, the docs confirmed it's an
   OIDC claim rather than an expression context. Fixed before #64 merged — `shared-ref` now
   defaults to `v2`, with a comment that it must track the major tag.
2. **The org-variable diagnosis was wrong.** I concluded contact-intelligence and ari-website
   needed an org-level selected-repositories grant. Areté doesn't use org-level Actions variables
   at all — they're repo-level everywhere, and those two repos were simply missing copies. The
   `admin:org` 403 masked this from me; one `gh variable list` would have shown it. Corrected by
   Dominick, then fixed by copying the vars in.

## Follow-ups this surfaced (not in these PRs)

- **`pr-to-main-hooks.yml` has the same disease, worse** — 6 Infisical inputs. The
  `/github-actions` folder would collapse it to zero the same way.
- **Nothing enforces the 4 `INFISICAL_*` repo variables on a new repo**, and the failure mode is
  silent: an empty identity resolves to no auth rather than a config-time error. A bootstrap script
  or a runbook checklist would prevent the next repeat.
- **areteos-py has two priority-label schemes** — native `priority-high/medium/low` on 244+ issues,
  plus the fleet-standard `P1`–`P4` I created. New issues get `P1`–`P4`; the history is untouched
  and remapping is a separate decision.
- **contact-intelligence CI doesn't run on pushes to develop** — hence the 2-month lint drift.
