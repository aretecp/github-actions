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
| `ecs-service` | shipped — Sextant is the consumer (`arilearn-phx#1577`) |
| `lambda-image` | next — `arilearn-phx`'s extractor sidecar is the consumer |

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
read and rewrite each other's compose files mid-flight — and since both
sides also *write* those compose files before running Compose, the race
starts there, not at `up -d`. `flock -w 900
/var/lock/<repo-dir-basename>-compose.lock` wraps from the compose-file
writes through `up -d`, making a deploy wait for a boot to finish rather
than race it; 900s matches this action's `command-timeout` default of 1800s
so the wait cannot silently outlive the SSM command. Released before the
healthcheck poll, which doesn't touch shared state and shouldn't make a
concurrent deploy wait for it too. Any other script bringing this project up
must take the same lock, starting before it writes any compose file, or it
reintroduces the race.

## `ecs-service`

Deploys onto an existing Fargate service. Registers a new task definition
revision (only the named container's image changes — everything else carries
over from what Terraform last applied), optionally gates on a one-off
migration task, updates the service, waits for it to stabilize, then
optionally runs a post-deploy task and a healthcheck.

```yaml
  - uses: aretecp/github-actions/actions/load-infisical-secrets@v2
    id: env
    with:
      method: oidc
      identity-id: ${{ vars.INFISICAL_OIDC_IDENTITY_ID }}
      project-slug: ${{ vars.INFISICAL_INTERNAL_PROJECT_SLUG }}
      environment: prod
      path: /sextant
      export-as-env: dotenv
      dotenv-output-path: ${{ runner.temp }}/.env

  - uses: aretecp/github-actions/actions/aws-deploy-core@v2
    with:
      target: ecs-service
      aws-role-arn: ${{ vars.SEXTANT_DEPLOY_ROLE_ARN }}
      ssm-prefix: /sextant/prod
      image: ${{ steps.build.outputs.image }}
      container-name: app
      env-file-path: ${{ runner.temp }}/.env
      migrate-command: '["/app/bin/migrate"]'
      healthcheck-url: https://sextant.lumistlabs.ai/healthz
```

### Subnets and security groups are never an input

A one-off migration or post-deploy task runs with the **service's own**
`networkConfiguration`, read fresh from `describe-services` rather than
asked of the caller — the same reasoning `ec2-compose` doesn't take an SSH
key: the fewer places a network path is spelled out, the fewer places it can
drift from what the service itself actually uses.

### The task definition is cloned, not templated

`register-task-definition` gets the current revision's JSON back from
`describe-task-definition`, with only the named container's `image` field
changed and the fields `register` rejects (`taskDefinitionArn`, `revision`,
`status`, ...) stripped. No task-definition template lives in this repo or
the caller's — Terraform is still the only thing that decides roles, sizing,
volumes and network mode.

### The migration gate runs before `update-service`, never after

A migration that fails must never leave the service pointed at the revision
it failed on. `run-task` on the new revision, wait for `STOPPED`, check the
container's `exitCode` — only then does `update-service` run.

## Config comes from SSM

Terraform writes these parameters, so they cannot drift from the resources they
name. Convention is `{ssm-prefix}/{name}`:

| Target | Parameters read |
|---|---|
| `s3-cloudfront` | `s3-bucket-name`, `cloudfront-distribution-id` |
| `ec2-compose` | none — it is handed its instance id directly |
| `ecs-service` | `ecs-cluster-name`, `ecs-service-name`, `ecs-task-family`, `env-file-s3-uri` |

A missing parameter fails with the full path in the error, before anything is
mutated. The alternative — repository variables with hardcoded fallbacks, as
`arilearn-phx` does today — silently deploys to whatever the fallback names.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `target` | yes | — | `s3-cloudfront`, `ec2-compose` or `ecs-service` |
| `aws-role-arn` | yes | — | caller needs `id-token: write` |
| `aws-region` | no | `us-east-1` | |
| `dry-run` | no | `false` | resolves config and reports, mutates nothing |
| `ssm-prefix` | s3-cloudfront, ecs-service | — | must start with `/` |
| `source-dir` | s3-cloudfront | — | built directory to sync |
| `delete-removed` | no | `true` | `--delete` on the sync |
| `invalidation-paths` | no | `/*` | space-separated |
| `wait-for-invalidation` | no | `true` | see below |
| `instance-id` | ec2-compose | — | needs the SSM agent + instance profile |
| `repo-dir` | ec2-compose | — | absolute path to the checkout on the host |
| `ref` | ec2-compose | — | git ref to check out on the host |
| `env-parameter-name` | ec2-compose | — | SecureString holding the dotenv |
| `image` | ec2-compose, ecs-service | — | full pre-built image reference |
| `env-file-path` | no | — | local dotenv, uploaded to env-parameter-name (ec2-compose) or env-file-s3-uri (ecs-service) |
| `env-file-name` | no | `.env` | ec2-compose: filename on the host |
| `compose-file` | no | `docker-compose.yml` | ec2-compose: space-separated for an override stack |
| `compose-profiles` | no | — | ec2-compose: space-separated `--profile` values |
| `healthcheck-url` | no | — | curled on the host (ec2-compose) or from the runner (ecs-service) |
| `command-timeout` | no | `1800` | ec2-compose: seconds; a cold build outlasts less |
| `container-name` | ecs-service | — | container definition to point at `image` |
| `migrate-command` | no | — | ecs-service: JSON array, gating one-off task before `update-service`; empty skips |
| `post-deploy-command` | no | — | ecs-service: JSON array, one-off task after steady state; empty skips |
| `task-timeout` | no | `600` | ecs-service: seconds to wait for a one-off task to stop |

## Outputs

`bucket`, `distribution-id`, `invalidation-id`, `command-id`, `task-definition-arn`.

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
rollback is repointing at a previous tag. `ecs-service` is the same shape:
every deploy registers a new, immutable task definition revision, so rollback
is `aws ecs update-service --task-definition <previous-revision-arn>` — no
input for it here, since the previous ARN is exactly what the prior workflow
run's `task-definition-arn` output already recorded.

## Failure notification

Not in this action. A composite action cannot reliably express "notify if
anything in this workflow failed", so it belongs in the calling workflow with
`if: failure()` at job level — and deliberately **not** scoped to a GitHub
environment, since a notification waiting on a required reviewer is a
notification nobody gets.
