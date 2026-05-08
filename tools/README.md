# `tools/`

**Admin / one-off bash scripts** run by a maintainer from a local checkout. These don't ship to consumer workflows — they manage org-wide GH config (secrets, vars, env stores) where `gh` CLI auth as a human user is required.

For runtime scripts that consumer workflows fetch + execute on the VPS, see [`../scripts/`](../scripts/).

## Available tools

| Script | Description | Audience |
|---|---|---|
| [`sync-infisical-config.sh`](sync-infisical-config.sh) | Mirror org-level Infisical secrets/vars to per-repo level across N repos. Workaround for GitHub Free org's lack of org-secret cascade to private repos. Run on initial setup, after rotating credentials, or when adding a new consumer repo. | Maintainer |
| [`cleanup-areteos-after-prod.sh`](cleanup-areteos-after-prod.sh) | Delete now-redundant per-repo / per-environment GH secrets in `aretecp/areteos` after both prod and dev workflows finish migrating to Infisical. | Maintainer, post-migration |
| [`cleanup-arilearn-phx-after-prod.sh`](cleanup-arilearn-phx-after-prod.sh) | Same idea for `aretecp/arilearn-phx`. | Maintainer, post-migration |

## Usage

Clone this repo, `chmod +x` if needed (the scripts already are), follow the per-script header for required env vars or interactive prompts, run from the repo root.

These scripts assume:
- `gh` CLI is authenticated as an org admin (`gh auth status` shows admin scope)
- `bash 3.2+` (macOS default works; uses parallel arrays, no associative arrays)
- Network access to GitHub API + Infisical where applicable

## Why a separate directory?

`scripts/` is for runtime-shared utilities consumer workflows fetch via curl — public stable URLs, security-sensitive (executed unattended), version-pinned. `tools/` is for admin one-offs — invoked by hand, may make destructive changes (delete secrets, alter env config), require human attention.

Mixing the two in one directory blurred audiences and security models. Splitting clarifies: anything in `scripts/` is OK to fetch from a workflow; anything in `tools/` is local-only.
