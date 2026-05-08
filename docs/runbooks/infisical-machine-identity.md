# Runbook: Infisical machine identity for shared GitHub Actions

How the `aretecp/github-actions` shared actions authenticate to Infisical, and how to rotate, scope, or expand access. Owned by the platform team.

## Background

The shared `load-infisical-secrets` action uses **Universal Auth**. Consumer workflows pass an `INFISICAL_CLIENT_ID` + `INFISICAL_CLIENT_SECRET` to the action, which exchanges them for a short-lived Infisical access token, then fetches the requested secrets.

Storing these credentials as **`aretecp` org-level GitHub Actions secrets** (with `--visibility selected`) means individual repos don't manage their own copies — they opt in to the org secret instead.

## Identity

| Field | Value |
|---|---|
| Name | `gh-actions-shared` |
| Auth method | Universal Auth |
| Token TTL | 15 minutes (workflows refresh per run) |
| Default permissions | **Read-only** on environments |
| Project access | Granted **per project** as workflows opt in (not `*`) |
| Trusted IPs | Open initially; tighten to GitHub Actions IP ranges if appetite grows |

When a new repo wants to use the shared action against a new Infisical project, **grant the existing `gh-actions-shared` identity read access on that project** — don't create a new identity per repo.

## GitHub org secret setup

> Run these from a terminal where the credential values are known. Do **not** paste the client secret into chat, AI tools, or anywhere it can be logged.

The `gh secret set` command with no `--body` flag reads the value from stdin, so the secret never appears as a shell argument:

```bash
# Client ID — identifier, less sensitive but still treat as secret
gh secret set INFISICAL_CLIENT_ID \
  --org aretecp \
  --visibility selected \
  --repos areteos
# (paste client_id, then Ctrl-D)

# Client secret — treat as a credential
gh secret set INFISICAL_CLIENT_SECRET \
  --org aretecp \
  --visibility selected \
  --repos areteos
# (paste client_secret, then Ctrl-D)
```

Verify (without revealing values):

```bash
gh secret list --org aretecp
```

You should see both names with `Visibility: SELECTED` and one selected repo.

### Adding more repos

When a new repo opts in:

```bash
gh secret set INFISICAL_CLIENT_ID --org aretecp --visibility selected \
  --repos areteos,<new-repo>
gh secret set INFISICAL_CLIENT_SECRET --org aretecp --visibility selected \
  --repos areteos,<new-repo>
```

`gh secret set` with `--repos` **replaces** the selected-repos list, so always pass the full list. To inspect the current list:

```bash
gh api /orgs/aretecp/actions/secrets/INFISICAL_CLIENT_ID/repositories --jq '.repositories[].name'
```

## Rotation

**Cadence: quarterly**, plus immediately on any suspected exposure (committed by accident, leaked in logs, contractor offboarding, etc.).

Steps:

1. **Generate a new client secret in Infisical**
   - Open the `gh-actions-shared` identity → Universal Auth → Client Secrets
   - Create a new secret. **Don't delete the old one yet.**
2. **Update the GitHub org secret**
   ```bash
   gh secret set INFISICAL_CLIENT_SECRET --org aretecp --visibility selected --repos areteos[,<more>]
   # (paste new client_secret, Ctrl-D)
   ```
3. **Trigger a smoke run** (re-run the latest workflow on the pilot repo, or push a no-op commit) — confirm a workflow that uses the action still succeeds.
4. **Revoke the old client secret** in Infisical only after a green workflow run.

No consumer-side changes are required — the secret name is unchanged, only the value rotates.

If a workflow run fails between steps 2 and 4, revert step 2 by setting the GitHub secret back to the old value (still active in Infisical), debug, retry. This is why step 4 lives at the end.

## Compromise response

If the client secret leaks (committed to a public repo, posted in a screenshot, etc.):

1. **Revoke the leaked client secret** in Infisical immediately.
2. Generate a replacement secret.
3. Run the rotation procedure above.
4. Audit Infisical access logs for the leaked secret's window of validity. File an incident note even if no anomalies are seen.
5. If the leak was via git history, scrub the commit (`git filter-repo` or BFG) and force-push — but **revocation comes first**; cleanup is secondary.

## Why not OIDC?

GitHub Actions can mint an OIDC token on each workflow run that Infisical's machine identity can trust directly — no long-lived `INFISICAL_CLIENT_SECRET` in GitHub at all. Better security posture, less rotation toil.

Out of scope for v1 of `load-infisical-secrets` — Universal Auth is simpler to bootstrap. Tracked as a follow-up; once the shared action and its consumers are stable, migrate.

## References

- Infisical docs: <https://infisical.com/docs/documentation/platform/identities/universal-auth>
- GitHub docs on org-level Actions secrets: <https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions#creating-secrets-for-an-organization>
- `gh secret` command reference: `gh secret --help`
- Related issues in this repo: #3 (action implementation), #5 (release docs — promote rotation section into the action README), #6 (pilot migration on `areteos`)
