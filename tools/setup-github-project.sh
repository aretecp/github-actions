#!/usr/bin/env bash
#
# setup-github-project.sh
#
# One-shot setup for the standard Areté project structure on a GitHub repo.
# Org defaults to 'aretecp'. Run with no args for an interactive prompt
# (repo, project title, copy-from picker).
#
# Two modes:
#
#   1. CLONE FROM TEMPLATE (recommended after the first setup)
#      --copy-from <project-number> clones an existing project's full
#      structure: views, fields, status options, README. Views are
#      UI-only in the GitHub API, so cloning is the only way to script
#      them out.
#
#        setup-github-project --repo new-repo \
#          --project-title "New Repo" --copy-from 2
#
#   2. GREENFIELD (first-time setup)
#      Without --copy-from (or with --greenfield), creates a fresh
#      project. Status options, description, README, and Points field
#      are configured. You'll then need to add the 5 standard views
#      manually in the UI (the script prints exact instructions).
#
#        setup-github-project --repo first-repo \
#          --project-title "First Repo" --greenfield
#
#   3. INTERACTIVE (no required args)
#      Prompts for repo, title, and shows a numbered picker of existing
#      projects to copy from.
#
#        setup-github-project
#
# After project creation, existing OPEN issues on the repo are
# automatically added to the project board. Use --include-closed to
# also pull closed issues, or --no-backfill to skip.
#
# In all modes, this also creates the standard label set on the repo:
# priority labels (P1-P4), domain labels (backend, frontend, infra,
# security, chore). Idempotent: re-running is safe.
#
# Requires: gh CLI authenticated with project, repo, admin:org scopes.
#           jq.
#
set -euo pipefail

ORG="aretecp"
REPO=""
PROJECT_TITLE=""
PROJECT_DESCRIPTION=""
COPY_FROM=""
COPY_FROM_SET=0
SKIP_LABELS=0
SKIP_PROJECT=0
SKIP_README=0
WANT_POINTS=1
NO_BACKFILL=0
INCLUDE_CLOSED=0

usage() { sed -n '2,45p' "$0" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --project-title) PROJECT_TITLE="$2"; shift 2 ;;
    --project-description) PROJECT_DESCRIPTION="$2"; shift 2 ;;
    --copy-from) COPY_FROM="$2"; COPY_FROM_SET=1; shift 2 ;;
    --greenfield) COPY_FROM=""; COPY_FROM_SET=1; shift ;;
    --skip-labels) SKIP_LABELS=1; shift ;;
    --skip-project) SKIP_PROJECT=1; shift ;;
    --skip-readme) SKIP_README=1; shift ;;
    --no-points) WANT_POINTS=0; shift ;;
    --no-backfill) NO_BACKFILL=1; shift ;;
    --include-closed) INCLUDE_CLOSED=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

# Cross-platform timeout wrapper — Linux has 'timeout', macOS+coreutils
# has 'gtimeout', otherwise fall back to a perl alarm (perl ships on
# every Mac). Used to bound gh API calls that can hang on 504s.
TIMEOUT_KIND=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_KIND="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_KIND="gtimeout"
elif command -v perl >/dev/null 2>&1; then
  TIMEOUT_KIND="perl"
fi

with_timeout() {
  local sec="$1"; shift
  case "$TIMEOUT_KIND" in
    "")        "$@" ;;
    "perl")    perl -e 'alarm shift @ARGV; exec @ARGV' "$sec" "$@" ;;
    *)         $TIMEOUT_KIND "$sec" "$@" ;;
  esac
}

# Interactive mode if any required arg is missing.
INTERACTIVE=0
[[ -z "$REPO" || -z "$PROJECT_TITLE" ]] && INTERACTIVE=1

if [[ $INTERACTIVE -eq 1 ]]; then
  echo "==> Interactive setup (org: @$ORG)"
  echo

  # Repo
  while [[ -z "$REPO" ]]; do
    read -r -p "Repo name (under @$ORG): " REPO
    REPO="${REPO## }"; REPO="${REPO%% }"
    if [[ -z "$REPO" ]]; then
      echo "  ! repo name required"
      continue
    fi
    if ! gh repo view "${ORG}/${REPO}" >/dev/null 2>&1; then
      echo "  ! ${ORG}/${REPO} not accessible — check auth or typo"
      REPO=""
    fi
  done

  # Project title (default: repo name)
  if [[ -z "$PROJECT_TITLE" ]]; then
    read -r -p "Project title [${REPO}]: " PROJECT_TITLE
    PROJECT_TITLE="${PROJECT_TITLE:-$REPO}"
  fi

  # Copy-from picker — only if not already set via flag
  if [[ $COPY_FROM_SET -eq 0 ]]; then
    echo
    echo "Available projects under @$ORG:"

    PROJECTS_JSON=""
    HAS_LIST=0
    # gh project list can 504 on orgs with many projects — bound each
    # attempt with a hard timeout and retry once.
    for attempt in 1 2; do
      if PROJECTS_JSON=$(with_timeout 25 \
            gh project list --owner "$ORG" --format json --limit 50 2>/dev/null) \
         && echo "$PROJECTS_JSON" | jq -e '.projects' >/dev/null 2>&1; then
        HAS_LIST=1
        break
      fi
      echo "  ! attempt $attempt: GitHub API slow/unavailable, retrying..." >&2
      sleep 3
    done

    if [[ $HAS_LIST -eq 1 ]]; then
      echo "$PROJECTS_JSON" \
        | jq -r '.projects | sort_by(.number) | .[] | "  \(.number)\t\(.title)"'
    else
      echo "  ! could not fetch project list (GitHub API timeout)."
      echo "    Browse projects at: https://github.com/orgs/$ORG/projects"
      echo "    You can still type a project number below if you know it."
    fi
    echo "  n     (greenfield — no copy)"
    echo

    while :; do
      read -r -p "Copy from which project? [number / n]: " CHOICE
      CHOICE="${CHOICE## }"; CHOICE="${CHOICE%% }"
      if [[ "$CHOICE" == "n" || "$CHOICE" == "N" || -z "$CHOICE" ]]; then
        COPY_FROM=""
        break
      fi
      if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
        if [[ $HAS_LIST -eq 1 ]]; then
          if echo "$PROJECTS_JSON" | jq -e --argjson n "$CHOICE" \
               '.projects[] | select(.number == $n)' >/dev/null; then
            COPY_FROM="$CHOICE"
            break
          fi
          echo "  ! invalid pick — enter a project number from above or 'n'"
        else
          # No list to validate against — trust the user's number.
          COPY_FROM="$CHOICE"
          break
        fi
      else
        echo "  ! invalid input — enter a number or 'n'"
      fi
    done
  fi
  echo
fi

[[ -z "$ORG" || -z "$REPO" || -z "$PROJECT_TITLE" ]] && usage

[[ -z "$PROJECT_DESCRIPTION" ]] && \
  PROJECT_DESCRIPTION="Issue tracking and roadmap for ${ORG}/${REPO}."

REPO_FULL="${ORG}/${REPO}"

gh repo view "$REPO_FULL" >/dev/null 2>&1 || {
  echo "Repo $REPO_FULL not accessible (auth? typo?)" >&2; exit 1; }

echo "==> $REPO_FULL → project '$PROJECT_TITLE' under @$ORG"
[[ -n "$COPY_FROM" ]] && echo "    cloning from project #$COPY_FROM"
echo

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

create_label() {
  local name="$1" color="$2" desc="$3" out
  # Case-insensitive existence check — repos can come pre-seeded with
  # labels in different casing (e.g. "Chore" vs "chore").
  if gh label list --repo "$REPO_FULL" --limit 200 --json name -q '.[].name' \
       | grep -Fxqi "$name"; then
    echo "  · label exists: $name"
    return 0
  fi
  # Defense-in-depth: tolerate "already exists" errors so a label
  # collision can't halt the entire run before project setup.
  if out=$(gh label create "$name" --color "$color" --description "$desc" \
             --repo "$REPO_FULL" 2>&1); then
    echo "  + label: $name"
  elif echo "$out" | grep -qi "already exists"; then
    echo "  · label exists: $name (skipped on collision)"
  else
    echo "  ! failed to create label $name: $out" >&2
    return 1
  fi
}

if [[ $SKIP_LABELS -eq 0 ]]; then
  echo "==> Labels (creating standard set on $REPO_FULL)"
  # Priority — required by the @claude triage prompt
  create_label "P1-critical" B60205 "Critical: drop everything"
  create_label "P2-high"     D93F0B "High: this sprint"
  create_label "P3-medium"   FBCA04 "Medium: next sprint"
  create_label "P4-low"      C5DEF5 "Low: when there's time"
  # Domain
  create_label "backend"     1d76db "Backend / API / services"
  create_label "frontend"    0075ca "Frontend / LiveView / UI"
  create_label "infra"       BFD4F2 "Infra / deploy / CI / Docker"
  create_label "security"    e11d48 "Security / auth / access control"
  create_label "chore"       cfd3d7 "Maintenance / refactor / cleanup"
  echo "  · labels phase complete"
  echo
fi

# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------

[[ $SKIP_PROJECT -eq 1 ]] && { echo "==> Skipping project setup"; exit 0; }

echo "==> Project"
echo "  · checking for existing project '$PROJECT_TITLE' under @$ORG..."

# Find existing
PROJECT_NUMBER=$(gh project list --owner "$ORG" --format json --limit 100 \
  | jq -r --arg t "$PROJECT_TITLE" \
      '.projects[] | select(.title == $t) | .number' \
  | head -1)

if [[ -n "$PROJECT_NUMBER" ]]; then
  echo "  · project exists: #$PROJECT_NUMBER (skipping create)"
else
  if [[ -n "$COPY_FROM" ]]; then
    # Clone from template via GraphQL — only way to bring views along.
    # We need the source project's NODE ID and the org's NODE ID for
    # copyProjectV2's input.
    SRC_PROJECT_ID=$(gh api graphql -f query='
      query($login: String!, $num: Int!) {
        organization(login: $login) {
          projectV2(number: $num) { id }
        }
      }' -f login="$ORG" -F num="$COPY_FROM" \
      | jq -r '.data.organization.projectV2.id')

    [[ -z "$SRC_PROJECT_ID" || "$SRC_PROJECT_ID" == "null" ]] && {
      echo "  ! could not resolve source project #$COPY_FROM under @$ORG" >&2
      exit 1; }

    OWNER_NODE_ID=$(gh api graphql -f query='
      query($login: String!) { organization(login: $login) { id } }' \
      -f login="$ORG" | jq -r '.data.organization.id')

    echo "  + cloning project from #$COPY_FROM"
    PROJECT_NUMBER=$(gh api graphql -f query='
      mutation($projectId: ID!, $ownerId: ID!, $title: String!) {
        copyProjectV2(input: {
          projectId: $projectId,
          ownerId: $ownerId,
          title: $title,
          includeDraftIssues: false
        }) { projectV2 { number } }
      }' \
      -f projectId="$SRC_PROJECT_ID" \
      -f ownerId="$OWNER_NODE_ID" \
      -f title="$PROJECT_TITLE" \
      | jq -r '.data.copyProjectV2.projectV2.number')
    echo "  · cloned to #$PROJECT_NUMBER (views + fields + status + README copied)"
  else
    # Greenfield — make a fresh project.
    echo "  + creating project: $PROJECT_TITLE"
    PROJECT_NUMBER=$(gh project create --owner "$ORG" --title "$PROJECT_TITLE" --format json \
      | jq -r '.number')
  fi
fi

PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$ORG" --format json | jq -r '.id')
echo "  · number: $PROJECT_NUMBER  id: $PROJECT_ID"

# Always update description and README — clones inherit the source's
# description, which won't be specific to this repo.
gh project edit "$PROJECT_NUMBER" --owner "$ORG" --description "$PROJECT_DESCRIPTION" >/dev/null
echo "  + description set"

if [[ $SKIP_README -eq 0 ]]; then
  README=$(cat <<EOF
# ${PROJECT_TITLE}

Issue tracking and roadmap for [${REPO_FULL}](https://github.com/${REPO_FULL}).

## How items get here

- **\`@claude\` triage bot** auto-adds new issues. The bot labels (type / priority / domain), suggests a branch name, and estimates difficulty points. See \`.github/workflows/claude-issues.yml\`.
- **Manual add** for cross-repo work or epics that don't fit a single issue.

## Status meanings

| Status | What it means |
|---|---|
| Backlog | Captured but not yet committed. Awaiting triage, scoping, or sequencing. |
| Ready | Triaged with type / priority / points. Safe to pick up with \`/work-issue <N>\`. |
| In Progress | Branch open, work happening. Should have an assignee and a draft PR within ~1 day. |
| In Review | PR open and awaiting code review or QA. Move back to In Progress only if changes are large. |
| Done | Merged. Read-only. |

## Priority

| | |
|---|---|
| P1-critical | Drop everything. Production down or security-impacting. |
| P2-high | Land this sprint. |
| P3-medium | Next sprint candidate. |
| P4-low | When there's time. |

## Workflow

1. Open an issue (or \`@claude\` on an existing one) — bot triages.
2. \`/work-issue <N>\` from the repo — creates a branch off the configured \`base_branch\`.
3. Periodic \`develop → main\` PR promotes work to prod via tagged release.

See \`CLAUDE.md\` and \`docs/reference/workflows.md\` in the repo for the full playbook.
EOF
)
  gh project edit "$PROJECT_NUMBER" --owner "$ORG" --readme "$README" >/dev/null
  echo "  + README set"
fi

# ---------------------------------------------------------------------------
# Greenfield-only: status options + Points field
#
# When cloned, all of this comes from the source project — skip.
# ---------------------------------------------------------------------------

if [[ -z "$COPY_FROM" ]]; then
  echo "  · updating Status options"
  STATUS_FIELD_ID=$(gh project field-list "$PROJECT_NUMBER" --owner "$ORG" --format json \
    | jq -r '.fields[] | select(.name == "Status") | .id')

  if [[ -n "$STATUS_FIELD_ID" && "$STATUS_FIELD_ID" != "null" ]]; then
    gh api graphql -f query='
      mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
        updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: $options }) {
          projectV2Field { ... on ProjectV2SingleSelectField { id } }
        }
      }' \
      -f fieldId="$STATUS_FIELD_ID" \
      --raw-field options='[
        {"name":"Backlog","color":"GRAY","description":"Captured but not yet committed. Awaiting triage, scoping, or sequencing."},
        {"name":"Ready","color":"GREEN","description":"Triaged with type / priority / points. Safe to pick up with /work-issue <N>."},
        {"name":"In Progress","color":"YELLOW","description":"Branch open, work happening. Assignee + draft PR within ~1 day."},
        {"name":"In Review","color":"BLUE","description":"PR open and awaiting code review or QA."},
        {"name":"Done","color":"PURPLE","description":"Merged. Read-only."}
      ]' >/dev/null
    echo "  + Status options: Backlog / Ready / In Progress / In Review / Done"
  fi

  if [[ $WANT_POINTS -eq 1 ]]; then
    if gh project field-list "$PROJECT_NUMBER" --owner "$ORG" --format json \
         | jq -e '.fields[] | select(.name == "Points")' >/dev/null; then
      echo "  · field exists: Points"
    else
      gh project field-create "$PROJECT_NUMBER" --owner "$ORG" \
        --name "Points" --data-type NUMBER >/dev/null
      echo "  + field: Points"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Backfill — add existing repo issues to the project
# ---------------------------------------------------------------------------

if [[ $NO_BACKFILL -eq 0 ]]; then
  echo "==> Backfill: adding existing issues to project"

  # Build a set of issue numbers already on the board so we don't double-add.
  EXISTING_NUMS=$(gh project item-list "$PROJECT_NUMBER" --owner "$ORG" \
    --format json --limit 1000 \
    | jq -r '[.items[] | select(.content.type == "Issue")
        | select((.content.repository // "") | endswith("/'"$REPO"'"))
        | .content.number] | .[]?' 2>/dev/null || true)

  ISSUE_STATE="open"
  [[ $INCLUDE_CLOSED -eq 1 ]] && ISSUE_STATE="all"

  ISSUES_JSON=$(gh issue list --repo "$REPO_FULL" --state "$ISSUE_STATE" \
    --limit 1000 --json number,url,title)
  TOTAL=$(echo "$ISSUES_JSON" | jq 'length')

  ADDED=0
  SKIPPED=0
  FAILED=0

  if [[ "$TOTAL" -eq 0 ]]; then
    echo "  · no $ISSUE_STATE issues to backfill"
  else
    while IFS=$'\t' read -r NUM URL; do
      [[ -z "$NUM" ]] && continue
      if echo "$EXISTING_NUMS" | grep -Fxq "$NUM"; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      if gh project item-add "$PROJECT_NUMBER" --owner "$ORG" --url "$URL" \
           >/dev/null 2>&1; then
        ADDED=$((ADDED + 1))
        echo "  + #$NUM"
      else
        FAILED=$((FAILED + 1))
        echo "  ! failed to add #$NUM"
      fi
    done < <(echo "$ISSUES_JSON" | jq -r '.[] | "\(.number)\t\(.url)"')

    echo "  · backfill: added=$ADDED skipped=$SKIPPED failed=$FAILED (state=$ISSUE_STATE)"
  fi
  echo
fi

# ---------------------------------------------------------------------------
# Done — print follow-up instructions
# ---------------------------------------------------------------------------

PROJECT_URL="https://github.com/orgs/${ORG}/projects/${PROJECT_NUMBER}"
echo
echo "==> Done."
echo
echo "Project URL:    $PROJECT_URL"
echo "Project number: $PROJECT_NUMBER"
echo

if [[ -z "$COPY_FROM" ]]; then
  cat <<EOF
==> Manual UI step: add views

GitHub's GraphQL API has no createProjectV2View mutation — views must
be created in the UI. Open the project and click "+ New view" for each:

  1. Backlog        layout: Board       group by: Status
  2. Priority board layout: Board       group by: Labels  filter: label:P1-critical,P2-high,P3-medium,P4-low
  3. Team items     layout: Table       (no filter)
  4. All issues     layout: Table       (no filter)
  5. My items       layout: Table       filter: assignee:@me

Then mark the project as a template:
  Settings → Templates → toggle "Make template" on.

After that, future repos can skip the manual step:
  setup-github-project.sh --org $ORG --repo <new-repo> \\
    --project-title "<New Title>" --copy-from $PROJECT_NUMBER

EOF
fi

cat <<EOF
==> Wire the @claude triage bot

Add this block to ${REPO_FULL}'s CLAUDE.md (under the existing content):

## Project Config

\`\`\`yaml
pm_tool: github-projects
base_branch: develop
github_project_owner: ${ORG}
github_project_number: ${PROJECT_NUMBER}
github_project_statuses: [Backlog, Ready, In Progress, In Review, Done]
\`\`\`
EOF
