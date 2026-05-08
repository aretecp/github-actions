# Areté Capital Partners — Shared GitHub Actions

Reusable composite actions for `aretecp` repos. Drop-in `uses:` references with org defaults baked in — no copy-pasted workflow steps across repos.

## Available actions

| Action | Description | Status |
|---|---|---|
| [`load-infisical-secrets`](actions/load-infisical-secrets) | Load secrets from Infisical at workflow runtime via Universal Auth | _in development_ |

More to come — Tailscale connect, Slack notify, Elixir/OTP setup, uv/Python setup. Each ships as its own composite action under `actions/<name>/`.

## Usage

Pin to the moving major tag for non-breaking updates:

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1
  with:
    project-id: ${{ vars.INFISICAL_PROJECT_ID }}
    environment: prod
  env:
    INFISICAL_CLIENT_ID: ${{ secrets.INFISICAL_CLIENT_ID }}
    INFISICAL_CLIENT_SECRET: ${{ secrets.INFISICAL_CLIENT_SECRET }}
```

Or pin to a specific version / SHA for stricter reproducibility:

```yaml
- uses: aretecp/github-actions/actions/load-infisical-secrets@v1.0.0
- uses: aretecp/github-actions/actions/load-infisical-secrets@<full-commit-sha>
```

## Versioning

- `@v1` — moving major tag; tracks the latest `1.x.y`. Recommended for most consumers.
- `@v1.2.3` — exact version; pin if you need reproducibility but can tolerate manual upgrades.
- `@<sha>` — strictest. Pin if your security posture requires it.

Breaking changes bump the major. The `v1` tag stays on `1.x` forever.

## License

MIT — see [`LICENSE`](LICENSE).
