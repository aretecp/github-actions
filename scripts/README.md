# `scripts/`

**Runtime-shared bash utilities** consumed at deploy time by SSH-script workflows. Fetched from consumer workflows via `curl`, executed on the deploy target (VPS).

For admin / local-execution scripts run by a maintainer, see [`../tools/`](../tools/).

## Available scripts

| Script | Description |
|---|---|
| [`wait-for-healthy.sh`](wait-for-healthy.sh) | Poll `docker inspect` for a list of containers until all report `healthy`, or timeout (with optional log dump on failure) |

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
