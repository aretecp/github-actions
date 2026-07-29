# Plan: migrate the last 3 repos onto the shared deploy workflows

**Status**: Draft
**Created**: 2026-07-29
**Last updated**: 2026-07-29
**Process reference**: [`docs/runbooks/deploy-vps-migration.md`](../../runbooks/deploy-vps-migration.md)
— that runbook already prescribes the *how* (audit → dry-export → dev → prod). This plan is the
*who, in what order, and what's missing first*.

---

## Context

Four repos are fully on the shared workflows (`areteos`, `areteos-py`, `bd-pulse`, `beacon`).
Three are not, and all three call `tailscale/github-action@v3` **directly** — on a moving tag,
bypassing our SHA-pinned `tailscale-connect` wrapper.

That bypass is not theoretical. `contact-intelligence` prod deploy has been **broken since
2026-05-19** with a dead `TAILSCALE_AUTHKEY`, and the silent-success bug in the upstream action
disguised it as an SSH timeout (see aretecp/github-actions#68, and contact-intelligence#78).

### Scope

| Repo | Workflows | `load-infisical-secrets`? | Auth | Deploy target |
|---|---|---|---|---|
| `arilearn-phx` | deploy-prod, deploy-dev, **rollback-prod**, **copy-prod-db** | ✅ 2 loads each | OIDC | Postgres |
| `contact-intelligence` | deploy-prod, deploy-dev | ❌ none | Universal Auth | `/home/sglyon/contact-intelligence`, `docker-compose.yml` |
| `performance-review` | deploy-prod, deploy-dev | ❌ none | Universal Auth | `/home/sglyon/performance-review`, sqlite (`.db`) |

8 workflows total.

---

## Blocking prerequisites

### P1 — Seed Infisical app folders (contact-intelligence, performance-review)

The shared workflow renders `.env` **from Infisical**, so anything the app needs at runtime must
live in its folder first. Current gap:

| Repo | In Infisical today | Still only in GitHub secrets |
|---|---|---|
| `contact-intelligence` | `MICROSOFT_CLIENT_ID/SECRET/TENANT_ID` | `AUTH_SECRET`, `BREVO_API_KEY`, `OPENAI_API_KEY`, `PERPLEXITY_API_KEY`, `NEO4J_URI`, `NEO4J_USERNAME`, `NEO4J_PASSWORD`, `REDIS_URL`, `POSTGRES_URL` (~9) |
| `performance-review` | `ANTHROPIC_API_KEY`, `LOGFIRE_TOKEN`, `MICROSOFT_*` | (audit against its heredoc — likely few or none) |

**This is a human step and deliberately not automated here.** It means moving live production
credentials between systems; the value of each secret has to be read and re-entered. I am not
copying prod credentials around on my own initiative. Runbook §1 covers the audit, including the
multi-line-secret trap.

Note `/performance-review` also contains a lowercase `anthropic-api-key` duplicate — resolve which
one is authoritative while in there.

### P2 — Repo-level `INFISICAL_OIDC_IDENTITY_ID`

The shared workflows authenticate by OIDC; both Universal Auth repos are missing the identity
variable. Areté uses **repo-level** variables, not org-level (see
[[project_arete_repo_level_gh_vars]]).

- [ ] `performance-review` — has only the three project-slug vars, **missing the identity**
- [x] `contact-intelligence` — identity added 2026-07-28
- `arilearn-phx` — already present

Cheap to fix (`gh variable set`, repo admin is enough), and verifiable with a throwaway
push-triggered probe before trusting it.

### P3 — Merge aretecp/github-actions#68

Hardens `tailscale-connect` to fail when it never joins the tailnet, and bumps the internal
`tailscale-connect@v1` → `@v2` pins so the fix actually reaches `vps-deploy-core`. Landing this
*before* the migrations means every repo moved here inherits a loud failure instead of a
three-minute-later SSH timeout.

---

## Sequence — lowest blast radius first

The ordering principle: **the first thing we migrate should be the thing that is already broken.**

### Phase 1 — `contact-intelligence` dev

- [ ] P1 seeding for this repo, then runbook §2 dry-export: confirm the rendered `.env` matches
      what the current heredoc produces, key for key, **before** any deploy
- [ ] Replace `deploy-dev.yml` with a `deploy-vps-shared@v2` shim
- [ ] Deploy dev, verify containers healthy + app responds

Chosen first because its deploy is **already non-functional**, so the downside is bounded — we
cannot make it more broken. It also has the largest secret gap, which makes it the honest test of
whether P1 is fully understood.

### Phase 2 — `contact-intelligence` prod

- [ ] Only after dev has been stable through at least one real deploy
- [ ] Expect this to also *fix* contact-intelligence#78, since Tailscale creds then come from
      Infisical `/tailscale` rather than the dead repo-local `TAILSCALE_AUTHKEY`
- [ ] Close #78 referencing the migration

### Phase 3 — `performance-review` dev → prod

- [ ] P2 first (add the identity variable), then the same dev-then-prod pattern
- [ ] sqlite app: use `db-type: sqlite` and confirm `db-path` + `db-container` so the pre-deploy
      snapshot actually captures the database

### Phase 4 — `arilearn-phx` deploy-dev → deploy-prod

- [ ] Mechanically the easiest (already OIDC + `load-infisical-secrets`), so it comes late on
      purpose: nothing is broken there, and it is a live Postgres app with real users
- [ ] Postgres: `db-type: postgres`, plus `db-name` / `db-user`

### Phase 5 — `arilearn-phx` rollback-prod + copy-prod-db  ⚠️ HIGHEST RISK

- [ ] Do **not** batch these with Phase 4
- [ ] `rollback-vps-shared` restores a DB snapshot; `copy-prod-db-shared` **clobbers dev from
      prod**. Both are destructive, and the shared versions are typed-confirm gated
      (`RESTORE-DB` / `CLOBBER-DEV`) — verify those gates actually block before trusting them
- [ ] Exercise `copy-prod-db` first (it only writes to *dev*), and only then `rollback-prod`
- [ ] Verify the shared workflow never writes to the prod container

---

## Constraints (carried from prior migrations)

- `load-infisical-secrets@v2` in **env** mode, never `export-type: file` — file mode silently
  drops some secrets (hit `MICROSOFT_CLIENT_SECRET`). See [[project_infisical_single_quote_render]].
- **Never `--remove-orphans`** on Areté VPS deploys — Traefik is a separate compose stack and gets
  wiped. Use `--force-recreate`. See [[project_vps_never_remove_orphans]].
- App root is `/home/sglyon/<app>`; `repo-dir` follows it. See [[project_vps_app_root]].
- Every PR targets `develop` first; promotion to trunk is a separate, explicit merge.

## Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | A secret is missed in P1 → app boots with a missing env var | Runbook §2 dry-export diff, key-for-key, before deploying. `required-keys` input fails the deploy rather than starting a broken container |
| R2 | Multi-line secrets (PEM keys, certs) don't survive the dotenv render | Runbook §1.1 audit specifically covers this; check before migrating, not after |
| R3 | Phase 5 destroys data | Destructive workflows split into their own phase, dev-writing one first, confirm-gates verified explicitly |
| R4 | OIDC not actually trusted for a newly-migrated repo | Throwaway probe workflow per repo before the real deploy — this caught the missing variable on two repos on 2026-07-28 |
| R5 | Migrating dev and prod in one pass hides a fault until prod | Dev-then-prod is mandatory per repo, never batched |

## Out of scope

- Rotating the ~12 duplicated `ANTHROPIC_API_KEY` copies, or the lowercase
  `anthropic-api-key` / `ARILEARN_ANTHROPIC_API_KEY` naming drift. Separate cleanup.
- Migrating these repos off Universal Auth for anything other than deploys.
- `aretecp/infisical` — excluded from shared-workflow patterns by design; it deploys the Infisical
  service those workflows authenticate against.
