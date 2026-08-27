# Project Instructions

## Project Context
- State what this repo does and who it serves.
- List the real stack, test commands, and deployment surface.
- Keep project-specific rules here, not in global Codex setup.

## Workflow
- Use `/fix` for small, well-understood changes.
- Use `/plan` before multi-file or risky work.
- Keep plans in `docs/features/[feature]/PLAN.md`.
- Run `/end-session` before closing meaningful work.

## Runners and CI
- Read [`docs/runbooks/runners-and-ci.md`](docs/runbooks/runners-and-ci.md) before
  touching a workflow. It carries the runner rule, the concurrency policy, and the
  self-hosted traps.
- Run `actionlint -color -shellcheck=` before pushing a workflow change. The
  `runner` context in job-level `env:` does not warn — it makes the workflow
  invalid and every run fails at startup with no jobs and no log.
- After merging, move the `v2` tag. Consumers pin it, so a merge alone ships nothing.

## Verification
- Add the project test command here.
- Add the project lint/typecheck command here.
- Note any services that must be running locally.

## Project Config
```yaml
pm_tool: none
base_branch: main
test_commands: []
build_commands: []

# Uncomment when this repo uses GitHub Projects.
# github_project_owner: aretecp
# github_repo: repo-name
# github_project_number: 0
# github_project_statuses: [Backlog, Ready, In Progress, In Review, Done]
# github_project_priorities: [P0, P1, P2, P3]
# github_issue_types: {}
```

## Memory
- Session learnings go in `.codex/memory/session-log.md`.
- Long-lived rules go in `.codex/rules/`.
