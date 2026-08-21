# Shared AWS deploy action

**Status:** Ready
**Created:** 2026-08-21
**Issue:** #96
**Related:** `lumist-terraform-infrastructure` → `docs/features/lumios-aws-hosting/PLAN.md`
(Track A; independent of this) · `aretecp/lumios` → `docs/features/aws-hosting/PLAN.md` §5
(the original sketch, corrected below)

One shared way to deploy to AWS, so an app plugs in instead of hand-rolling a
workflow. Mirrors the `vps-deploy-core` shape: a core composite action wrapped by
thin reusable workflows.

---

## 1 · Start from what already works

Two AWS deploy workflows exist and are in production. **This is an extraction, not
a design exercise.**

| Workflow | Repo | Does |
|---|---|---|
| `deploy.yml` | `areteintelligence-site` | npm build → OIDC assume → read bucket + distribution id from SSM → `s3 sync --delete` → CloudFront invalidation |
| `deploy-extractor-sidecar.yml` | `arilearn-phx` | pytest gate → OIDC assume → ECR login → buildx push (sha + channel tags) → `lambda update-function-code --publish` → `wait function-updated` → SigV4-signed `/healthz` with retry |

Both already do OIDC-only auth with no long-lived keys. The Terraform side is
also already in place: `arete-intelligence-site/ssm.tf` and `lumilearn/ssm.tf`
publish the resource names, and `lumilearn/iam_github_deploy.tf` builds the
repo-scoped deploy role off foundation's OIDC provider.

**What both are missing**, and what the shared version exists to fix:

1. **No failure notification, in either one.** This is the exact scar from
   lumios's `deploy-prod.yml`: `TRAEFIK_TRUSTED_IPS` went missing from Infisical,
   **five consecutive prod deploys failed, and nobody noticed for three weeks** —
   because the pipeline fails safely and a safe failure looks like nothing
   changed. Neither AWS workflow calls `teams-notify`.
2. **The CloudFront invalidation is never waited on.** `deploy.yml` fires
   `create-invalidation` and exits green. The job passes while the edge still
   serves the old bundle.
3. **No pre-flight validation.** `deploy-vps-shared`'s `required-keys` has no
   equivalent here, so a missing SSM parameter surfaces as an `aws` CLI error
   partway through.

## 2 · Three corrections to the original sketch

The design in the lumios plan §5 was written before anyone counted consumers.
All three corrections make this smaller.

**`ecs-service` has no consumer — don't build it.** The sketch listed it first.
But `contact-intelligence/`'s Terraform is `data.tf`/`locals.tf`/`providers.tf`
only, LumiOS is going EC2 + compose over the tailnet, and nothing else in the
estate runs on ECS. Build it when something needs it — the sketch's own
instruction for `lambda`, applied consistently.

**`lambda-image` *does* have a consumer, today.** The sketch said "not built. Add
when something needs it." `arilearn-phx`'s extractor sidecar is that something,
and it is the more thoroughly built of the two existing workflows.

So the target list is what is actually deployed: **`s3-cloudfront` and
`lambda-image`.** `ec2-compose` is also dropped — LumiOS reuses
`deploy-vps-shared.yml@v2` over the tailnet, which is Track A's whole shortcut.

**The core does not own the build, and does not load Infisical.** Two changes
from the sketch, same reason. `vps-deploy-core` owns its build because compose
builds on the target host; here the build is npm, pnpm, docker or uv and is
irreducibly app-specific. And neither existing workflow touches Infisical — the
site reads SSM, the sidecar reads repo `vars`. A caller whose *build* needs
secrets composes `load-infisical-secrets@v2` ahead of this action.

That boundary is the whole defence against the input surface `deploy-vps-shared`
grew to — ~25 inputs, which its own plan flags as the warning sign. **Caller
builds and hands over an artifact path or an image URI. The core assumes the
role, resolves config, deploys, waits, verifies, and notifies on failure.**

## 3 · Shape

```
actions/aws-deploy-core/action.yml          ← target dispatch, the whole implementation
.github/workflows/deploy-aws-shared.yml     ← thin caller
.github/workflows/rollback-aws-shared.yml   ← thin caller, same core
```

Do not wrap `aws-actions/configure-aws-credentials` in our own action — one
library call, used directly inside the core. Same for `amazon-ecr-login`.

**Config comes from SSM, not repo `vars`.** Terraform writes the parameters, so
they cannot drift from the resources they name. `deploy.yml` already works this
way; the sidecar's `vars.EXTRACTOR_LAMBDA_FUNCTION_PROD || 'arilearn-extractor-dev'`
fallbacks are exactly the drift SSM removes. Convention:
`/{app}/{env}/{resource-name}`.

### Shared across both targets

OIDC role assume + region · SSM config resolution · **pre-flight validation** ·
deploy · **wait for the deploy to actually be live** · `teams-notify@v2` on
failure, with `if: failure()` at workflow level and **deliberately not scoped to
a GitHub environment** — a notification that waits on a required reviewer is a
notification nobody gets · `dry-run`.

Pre-flight also rejects inputs belonging to a *different* target than the one
selected. A silently-ignored input is a deploy that did not do what the caller
thought.

### Gotchas to encode, both learned the hard way

- **Lambda rejects OCI image indexes and attestation manifests.** `provenance:
  false` and `sbom: false` on the buildx push, or `update-function-code` fails on
  a manifest list. Already commented in `arilearn-phx`; belongs in the README.
- **An IAM-authed Function URL needs a SigV4-signed probe.** `curl --aws-sigv4
  "aws:amz:{region}:lambda"` with the session token in `x-amz-security-token`,
  and a retry budget — model cold start runs 30–60s.
- **Multi-GB image builds need disk reclaimed first.** `ubuntu-latest` ships
  ~14 GB free on `/`.

All three are build-side, so they live with the caller under §2's boundary.
**Trigger to revisit: a second container consumer.** At two, extract an
`ecr-build-push` action and move them in. At one, a shared build action is an
abstraction with a single caller.

## 4 · PR split

| # | What | Size | Needs |
|---|---|---|---|
| B1 | `actions/aws-deploy-core` — OIDC assume, SSM resolution, pre-flight, `s3-cloudfront` target, **invalidation wait**, `teams-notify` on failure, `dry-run`. Plus its README. | ~250 ln | — |
| B2 | `lambda-image` target in the same core: `update-function-code --publish`, `wait function-updated`, SigV4 `/healthz` with retry | ~120 ln | B1 |
| B3 | `deploy-aws-shared.yml` thin caller, root README rows, `docs/runbooks/deploy-aws.md` mirroring `deploy-vps-migration.md` | ~150 ln | B2 |
| B4 | **Validation gate.** Migrate `areteintelligence-site` to the shim. | ~-60 ln, other repo | B3 |
| B5 | Migrate `arilearn-phx`'s deploy job to the shim; its test and build jobs stay put | ~-80 ln, other repo | B4 |
| B6 | `rollback-aws-shared.yml` — see §5 | ~100 ln | B5 |

**B4 is the release gate, and it goes first for a reason.** `RELEASING.md`
requires a real consumer to exercise every changed action before the tag moves,
and the static site's failure mode is a stale CSS file. The sketch's rule holds:
prove it on a static site, never on LumiOS prod.

### Two release-mechanics constraints

**Merging to `main` cuts the release.** `release.yml` auto-bumps on the merge
commit's conventional prefix, so a `feat:` PR title *is* the release trigger.
B1–B3 therefore need `chore:`/`docs:` titles or a held merge until B4 has proven
them. New action with no change to existing ones is a **minor** bump on the
current major — additive, breaks no consumer.

**This repo is `main`-only, and that is deliberate.** There is no `develop`
branch and no environment to promote through — the actions apply wherever a
consumer pins them. So `main` is the base, and the `feature → develop → main`
flow that governs the Terraform repos does not apply.

## 5 · Rollback is not symmetric between the two targets

Worth deciding before B6 rather than during it.

**`lambda-image` is nearly free.** The sidecar already pushes both a sha-pinned
and a channel-tagged URI, and calls the sha one immutable. Rollback is
`update-function-code` at a previous sha URI — the mechanism exists, it just
needs exposing.

**`s3-cloudfront` has nothing to roll back to.** `s3 sync --delete` overwrites in
place and the previous build is gone. A real rollback needs either bucket
versioning plus a restore path, or keeping the last N build artifacts somewhere.
That is a Terraform change in `arete-intelligence-site/`, not a workflow input.

Recommendation: ship B6 with `lambda-image` rollback only, and state in the
README that `s3-cloudfront` rollback is a redeploy of an older ref. Do not
pretend to a capability the bucket does not have.

## 6 · Out of scope

`ecs-service` and `ec2-compose` targets (§2 — no consumers), an `ecr-build-push`
action (§3 — one consumer), and Cloudflare Workers deploys. `lumist-website`
deploys to Workers via `scripts/cf-deploy.mjs` and is not an AWS consumer; its
branch mapping deliberately lives in the script rather than the workflow, and
that shape should not be pulled in here.
