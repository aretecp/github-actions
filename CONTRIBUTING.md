# Contributing

This repo holds shared **composite GitHub Actions** for `aretecp` repos. Each action lives in its own directory under `actions/` and is consumed by other repos via `uses: aretecp/github-actions/actions/<name>@<ref>`.

## Repo layout

```
.
├── actions/
│   └── <action-name>/
│       ├── action.yml         # required — composite action definition
│       └── README.md          # required — usage docs for consumers
├── .github/
│   ├── ISSUE_TEMPLATE/
│   ├── pull_request_template.md
│   └── workflows/             # smoke-tests for actions in this repo
└── CONTRIBUTING.md
```

One action per directory. The directory name is the action's public name — pick it carefully.

## Adding a new action

1. **Open an issue first** using the `Feature request` template. Describe the problem you're solving across repos and sketch the inputs/outputs. Get a thumbs-up before writing code.
2. **Branch off `main`** with `feat/<issue#>-<short-name>` (e.g. `feat/12-tailscale-connect`).
3. **Create `actions/<name>/action.yml`** following the schema below.
4. **Write `actions/<name>/README.md`** — show a `uses:` block, document every input and output, list any required secrets/permissions.
5. **Add a smoke-test workflow** under `.github/workflows/smoke-<name>.yml` that exercises the action on `pull_request` against the changed paths. Until #4 lands as a reusable scaffold, copy the pattern from an existing smoke workflow.
6. **Open a PR** linking the issue with `Closes #N`. Verify the smoke-test workflow is green on the PR.

## `action.yml` schema

Composite actions only — no Docker, no JS bundles. Keep dependencies to widely-available shell tools or `setup-*` actions from the marketplace.

```yaml
name: <Human-readable name>
description: <One sentence — what it does, who calls it>

inputs:
  <input-name>:
    description: <What it is, why it's needed>
    required: true | false
    default: <only if required: false>

outputs:
  <output-name>:
    description: <What downstream steps can use this for>
    value: ${{ steps.<id>.outputs.<key> }}

runs:
  using: composite
  steps:
    - name: <Verb-first step name>
      shell: bash
      run: |
        # bash steps must set `shell:` explicitly — composite actions don't inherit it
        ...
```

Conventions:

- **Input names** are `kebab-case` (`project-id`, not `projectId` or `project_id`).
- **Required vs optional** — required inputs have no `default`; optional inputs always have one.
- **Secrets** are *never* declared as inputs. Pass them through `env:` at the call site so they don't leak into the workflow log on misuse. Document the expected env var names in the action's README.
- **Outputs** must come from a step with an explicit `id:`. Don't rely on implicit step IDs.
- **Idempotency** — composite actions get re-run on `act` and during PR rebases. Don't write to shared state without guards.

## Versioning

We follow semver and ship a moving major tag.

- `vMAJOR.MINOR.PATCH` — annotated tags, immutable.
- `vMAJOR` — moving tag (`v1`, `v2`, ...). Always points to the latest `MAJOR.x.y`. Most consumers pin to this.

Bump rules:

| Change | Bump |
|---|---|
| Internal refactor, no caller-visible change | patch |
| New optional input, new output, additional behavior behind a flag | minor |
| Renamed/removed input or output, default change, behavior change that affects existing callers | **major** — bump the moving tag too |

**Never amend a published tag.** If you need to fix a release, cut a new patch and update the moving major tag to point at it.

When you bump major, the old `vN` tag stays where it is — it does not advance. Consumers on `@v1` keep getting `1.x.y`; only repos that explicitly retarget to `@v2` get the new behavior.

## Smoke tests

Every action needs a smoke-test workflow that runs on PRs touching `actions/<name>/**`. The smoke test should:

- Run on the OS(es) the action supports (`ubuntu-latest` at minimum)
- Exercise the action with realistic inputs
- Assert outputs / side effects via subsequent steps
- Use a non-prod environment / project where applicable

If your action needs secrets, get them added as **org-level** Actions secrets so other consumers can use the same names — don't bake repo-specific secret names into the action.

## Commit + PR conventions

- Conventional prefixes: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`.
- Tag the issue number when the commit is directly tied to one: `feat: #12 add tailscale-connect action`.
- One logical change per PR. If you find yourself touching multiple actions, split it.
- The PR template asks for test evidence — link the green smoke-test run.

## Releases

Cutting a release is its own task tracked in #5 (initial process) and any follow-up issues. The short version: tag `vX.Y.Z`, then force-update the moving `vX` tag to point at the new annotated tag. Do not delete or rewrite published versioned tags.

## Questions

File an issue or ping `@DominickGiordano`.
