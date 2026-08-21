# `aws-deploy-core`

Assume an AWS role via GitHub OIDC, resolve the target's resource names from SSM,
deploy, and wait for the deploy to actually be live.

One implementation, thin callers — the same shape as
[`vps-deploy-core`](../vps-deploy-core).

## What it does not do

**It does not build.** The build is npm, pnpm, docker or uv depending on the app,
so it stays with the caller. That boundary is the only thing keeping the input
surface here from growing the way `deploy-vps-shared`'s did (~25 inputs).

**It does not load Infisical.** Neither existing AWS deploy needed it — config
comes from SSM and auth from OIDC. If a caller's *build* needs secrets, it
composes [`load-infisical-secrets`](../load-infisical-secrets) ahead of this.

## Targets

| `target` | Status |
|---|---|
| `s3-cloudfront` | shipped |
| `lambda-image` | next — `arilearn-phx`'s extractor sidecar is the consumer |
| `ecs-service` | not built. Nothing runs on ECS yet; added when something does |

## Usage

```yaml
permissions:
  id-token: write   # required for OIDC
  contents: read

steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-node@v4
    with: { node-version: 20, cache: npm }
  - run: npm ci && npm run build          # the caller builds

  - uses: aretecp/github-actions/actions/aws-deploy-core@v2
    with:
      target: s3-cloudfront
      aws-role-arn: ${{ secrets.AWS_ROLE_ARN }}
      ssm-prefix: /arete-intelligence-site/prod
      source-dir: out
```

## Config comes from SSM

Terraform writes these parameters, so they cannot drift from the resources they
name. Convention is `{ssm-prefix}/{name}`:

| Target | Parameters read |
|---|---|
| `s3-cloudfront` | `s3-bucket-name`, `cloudfront-distribution-id` |

A missing parameter fails with the full path in the error, before anything is
mutated. The alternative — repository variables with hardcoded fallbacks, as
`arilearn-phx` does today — silently deploys to whatever the fallback names.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `target` | yes | — | `s3-cloudfront` |
| `aws-role-arn` | yes | — | caller needs `id-token: write` |
| `aws-region` | no | `us-east-1` | |
| `ssm-prefix` | yes | — | must start with `/` |
| `dry-run` | no | `false` | resolves config and reports, mutates nothing |
| `source-dir` | s3-cloudfront | — | built directory to sync |
| `delete-removed` | no | `true` | `--delete` on the sync |
| `invalidation-paths` | no | `/*` | space-separated |
| `wait-for-invalidation` | no | `true` | see below |

## Outputs

`bucket`, `distribution-id`, `invalidation-id`.

## Three things it does that the workflows it replaces did not

**It waits for the invalidation.** `areteintelligence-site`'s workflow fired
`create-invalidation` and exited, so the job went green while the edge still
served the previous bundle. "Deployed" and "reported deployed" were different
things by several minutes.

**It validates before touching AWS.** `deploy-prod.yml` in `lumios` is the
cautionary tale: a missing key failed five consecutive prod deploys forty lines
into an ssh step, and nobody noticed for three weeks — because a pipeline that
fails safely looks exactly like nothing changed.

**It refuses an empty `source-dir`.** With `--delete`, syncing an empty directory
empties the bucket. A build that silently produced nothing should fail the
deploy, not publish its absence.

## Rollback

Not symmetric across targets, so it is deliberately not offered here uniformly.

`s3 sync --delete` overwrites in place and the previous build is gone, so a
static-site rollback is a redeploy of an older ref. A real one needs bucket
versioning or retained artifacts — a Terraform change, not a workflow input.
`lambda-image` will be different: the image is sha-pinned and immutable, so
rollback is repointing at a previous tag.

## Failure notification

Not in this action. A composite action cannot reliably express "notify if
anything in this workflow failed", so it belongs in the calling workflow with
`if: failure()` at job level — and deliberately **not** scoped to a GitHub
environment, since a notification waiting on a required reviewer is a
notification nobody gets.
