# `scripts/`

**Runtime-shared bash utilities** consumed at deploy time by SSH-script workflows. Fetched from consumer workflows via `curl`, executed on the deploy target (VPS).

For admin / local-execution scripts run by a maintainer, see [`../tools/`](../tools/).

## Available scripts

| Script | Description | Runs on |
|---|---|---|
| [`wait-for-healthy.sh`](wait-for-healthy.sh) | Poll `docker inspect` for a list of containers until all report `healthy`, or timeout (with optional log dump on failure) | VPS |
| [`docker-prune.sh`](docker-prune.sh) | Reclaim Docker disk (dangling images, aged build cache), then exit non-zero if usage or free space breaches a threshold | VPS |
| [`install-docker-prune.sh`](install-docker-prune.sh) | Install `docker-prune.sh` on a VPS and schedule it — systemd timer where sudo allows, user crontab otherwise | VPS |
| [`entra-credential-scan.sh`](entra-credential-scan.sh) | Enumerate every Entra app registration and report each credential's expiry as JSON, soonest-first. Read-only Graph query. | Runner |

> **Note:** `entra-credential-scan.sh` is the exception to the "executed on the deploy
> target" rule above — it runs on the GitHub runner, not a VPS, and is checked out
> rather than curl'd. It lives here rather than in `tools/` because a workflow
> consumes it, not a maintainer at a terminal. See
> [`entra-secret-detector.yml`](../.github/workflows/entra-secret-detector.yml).

## Consuming a script in a workflow

Inside an SSH script (typical for deploy workflows that connect via Tailscale + SSH):

```yaml
- name: Deploy + wait for healthy
  uses: appleboy/ssh-action@v1
  with:
    host: ${{ secrets.VPS_TAILSCALE_IP }}
    username: ${{ secrets.VPS_USER }}
    key: ${{ secrets.VPS_SSH_KEY }}
    script: |
      cd ~/areteos
      docker compose -f docker-compose.prod.yml up -d --build

      # Pin to v1 (moving major) — picks up patch fixes automatically
      curl -fsSL "https://raw.githubusercontent.com/aretecp/github-actions/v1/scripts/wait-for-healthy.sh" \
        | TIMEOUT_SECONDS=150 \
          COMPOSE_FILE=docker-compose.prod.yml \
          ENV_FILE=.env \
          bash -s -- areteos_app areteos_db
```

## Docker disk cleanup on a VPS

`docker-prune.sh` is a scheduled janitor, not a workflow step. Install it once per box:

```bash
# From a checkout on the VPS
scripts/install-docker-prune.sh

# Or standalone
curl -fsSL "https://raw.githubusercontent.com/aretecp/github-actions/v2/scripts/install-docker-prune.sh" | bash
```

It exists because on 2026-08-14 the Areté VPS Docker data-root volume filled to
100% and every Postgres on the box refused to start. The previous janitor pruned
build cache only, and reported nothing anyone read.

**What it prunes:** dangling (untagged) images, then build cache older than 24h.
Images first — releasing their layers lets the cache prune drop the records that
referenced them.

**What it refuses to prune, and why:**

| Not run | Reason |
|---|---|
| `docker volume prune` | ~6.9GB across 25 unused volumes, including `areteos_test_pg` and the arilearn blue/green standby's data |
| `docker image prune -a` | ~12–15GB of images for stopped-but-live apps: `arilearn-phx-migrate`, `contact-intelligence-*`, `openpanel-*`, `litellm`, `clickhouse`, `neo4j` |
| `docker system prune -af` | Both of the above at once |
| `docker container prune` | On the Areté box the 168h filter would delete `arilearn-phx-app_green-1`, the blue/green standby. Reclaims 5.4MB. |

**Reading the result.** Exit 1 means usage is at/over `WARN_PCT` (85) or free
space is under `MIN_FREE_GB` (20) — actionable. Exit 4 means a prune step failed
but the disk is fine. A monitor should read the status file rather than the log:

```
$HOME/.local/state/docker-prune/status.json
```

```json
{"ts":"2026-08-14T17:33:42Z","host":"arete-aichat","usage_pct":52,"free_gb":92.0,
 "reclaimed_gb":0.5,"warn_pct":85,"min_free_gb":20,"exit_code":0,"breach":""}
```

Written atomically, so a poller can never catch it half-written. Both thresholds
matter: 8% of a 197GB volume is 15GB, which is under two areteos-py builds, so
percent alone under-reads the danger on a volume that size.

## Pinning

Pick the ref that matches your trust + reproducibility tradeoff:

| Pin | Use when |
|---|---|
| `https://raw.githubusercontent.com/aretecp/github-actions/v1/scripts/...` | Default. Get patch fixes automatically. |
| `https://raw.githubusercontent.com/aretecp/github-actions/v1.2.3/scripts/...` | You want exact reproducibility but can manually upgrade |
| `https://raw.githubusercontent.com/aretecp/github-actions/<full-sha>/scripts/...` | Strict — security-sensitive workflows |

## Why scripts instead of composite actions?

Composite actions execute on the GitHub-hosted runner. Most of our deploy logic happens **on the remote VPS via SSH**, where the GitHub runner can't reach Docker directly. A composite action wrapping `docker inspect` would have to either SSH for each call (slow + fragile) or shell out to `DOCKER_HOST=ssh://...` (workable but fiddly).

Bash scripts pulled at deploy time and executed in-context sidestep that entirely. Same destination as a composite action — single source of truth, version-pinnable — different mechanism.
