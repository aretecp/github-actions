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
| `ec2-compose` | shipped — LumiOS on AWS is the consumer |
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

## `ec2-compose`

Deploys a Docker Compose app onto an EC2 host **over SSM, not ssh**. The
instance profile already carries `AmazonSSMManagedInstanceCore`, so there is no
auth key to hold, no inbound port to open, and no long-lived credential anywhere
in the path.

```yaml
  - uses: aretecp/github-actions/actions/load-infisical-secrets@v2
    id: env
    with:
      method: oidc
      identity-id: ${{ vars.INFISICAL_OIDC_IDENTITY_ID }}
      project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
      environment: prod
      path: /lumios
      export-as-env: dotenv
      dotenv-output-path: ${{ runner.temp }}/.env

  - uses: aretecp/github-actions/actions/aws-deploy-core@v2
    with:
      target: ec2-compose
      aws-role-arn: ${{ vars.LUMIOS_DEPLOY_ROLE_ARN }}
      instance-id: ${{ vars.LUMIOS_INSTANCE_ID }}
      repo-dir: /opt/lumios
      ref: ${{ github.sha }}
      env-parameter-name: /lumios/prod/dotenv
      env-file-path: ${{ runner.temp }}/.env
      healthcheck-url: http://127.0.0.1:18000/health
```

### The dotenv does not travel through SendCommand

`SendCommand` parameters are retained on the command record and copied into
CloudWatch, so passing the rendered env that way would make every deploy a place
the app's secrets are written in plaintext.

Instead the action writes it to an SSM SecureString and the **host fetches it
with its own instance role**, scoped to that one parameter path. The remote
script writes it under `umask 077`.

### The remote script is passed as jq-built JSON

Not string-interpolated. A quote or newline in any input cannot break out of the
parameters document.

### Multiple compose files, and why LumiOS needs them

`compose-file` takes a space-separated list, one `-f` each in precedence order.
That exists because removing a service's dependency in Compose turns out to have
exactly one working mechanism, and it took measuring to find:

| Attempt | Result |
|---|---|
| `extends` in a second file | **fails.** `depends_on` is inherited, then errors as `depends on undefined service "db"` |
| `depends_on: []` in an override | **ignored.** The merge keeps the base's `depends_on` |
| `docker compose up --no-deps` | works, but drops *every* dependency — including the worker's migration-ordering gate on `app` |
| `depends_on: {db: !reset null}` in an override | **works.** Clears just that one key |

Paired with `profiles: ["local-db"]` on `db` in the same override, a plain `up`
then starts everything except the bundled database. Measured on Compose 5.0.2.

### Polling is manual, on `command-timeout`

`aws ssm wait command-executed` gives up after roughly 100 seconds, which a cold
image build outlasts every time. Both stdout and stderr are printed whatever the
outcome — a deploy that fails silently is the failure mode this action exists to
avoid.

### The compose section takes a lock

A host that self-provisions can be running its own boot-time `docker compose
up` on this same project directory when a deploy lands over SSM. Neither
Compose invocation takes a lock of its own, so two concurrent `up -d` calls
read and rewrite each other's compose files mid-flight. `flock -w 900
/var/lock/<repo-dir-basename>-compose.lock` around ECR login through `up -d`
makes a deploy wait for a boot to finish rather than race it; 900s matches
this action's `command-timeout` default of 1800s so the wait cannot silently
outlive the SSM command. Released before the healthcheck poll, which doesn't
touch shared state and shouldn't make a concurrent deploy wait for it too.
Any other script bringing this project up must take the same lock, or it
reintroduces the race.

## Config comes from SSM

Terraform writes these parameters, so they cannot drift from the resources they
name. Convention is `{ssm-prefix}/{name}`:

| Target | Parameters read |
|---|---|
| `s3-cloudfront` | `s3-bucket-name`, `cloudfront-distribution-id` |
| `ec2-compose` | none — it is handed its instance id directly |

A missing parameter fails with the full path in the error, before anything is
mutated. The alternative — repository variables with hardcoded fallbacks, as
`arilearn-phx` does today — silently deploys to whatever the fallback names.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `target` | yes | — | `s3-cloudfront` or `ec2-compose` |
| `aws-role-arn` | yes | — | caller needs `id-token: write` |
| `aws-region` | no | `us-east-1` | |
| `dry-run` | no | `false` | resolves config and reports, mutates nothing |
| `ssm-prefix` | s3-cloudfront | — | must start with `/` |
| `source-dir` | s3-cloudfront | — | built directory to sync |
| `delete-removed` | no | `true` | `--delete` on the sync |
| `invalidation-paths` | no | `/*` | space-separated |
| `wait-for-invalidation` | no | `true` | see below |
| `instance-id` | ec2-compose | — | needs the SSM agent + instance profile |
| `repo-dir` | ec2-compose | — | absolute path to the checkout on the host |
| `ref` | ec2-compose | — | git ref to check out on the host |
| `env-parameter-name` | ec2-compose | — | SecureString holding the dotenv |
| `env-file-path` | no | — | local dotenv to upload to that parameter |
| `env-file-name` | no | `.env` | filename on the host |
| `compose-file` | no | `docker-compose.yml` | space-separated for an override stack |
| `compose-profiles` | no | — | space-separated `--profile` values |
| `healthcheck-url` | no | — | curled on the host after `compose up` |
| `command-timeout` | no | `1800` | seconds; a cold build outlasts less |

## Outputs

`bucket`, `distribution-id`, `invalidation-id`, `command-id`.

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
