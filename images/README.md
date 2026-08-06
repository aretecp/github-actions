# CI base images

Prebuilt container images for `aretecp` CI jobs, published to GHCR by
[`ci-images.yml`](../.github/workflows/ci-images.yml).

## Why

Every self-hosted CI job used to open with the same step:

```yaml
- name: Install OS prereqs
  run: |
    apt-get update -qq
    apt-get install -y --no-install-recommends git ca-certificates ...
```

That step installs byte-identical content on every run, puts an apt mirror in
the critical path of every PR, and is dominated by `dpkg` fsyncing each
unpacked file. On a runner host with slow storage it reached **16 minutes** for
a single job. Baking the packages into an image moves the cost to a workflow
that runs only when a `Dockerfile` changes or on the weekly refresh.

## Available images

| Image | Base | Adds | Consumers |
|---|---|---|---|
| `ghcr.io/aretecp/ci-elixir:1.18.4-otp-27` | `elixir:1.18.4-otp-27-slim` | git, build-essential, curl, unzip, python3(-venv), Hex + Rebar, uv + managed CPython 3.12 | `areteos` `ci.yml` |
| `ghcr.io/aretecp/ci-elixir:1.19.5-otp-28` | `elixir:1.19.5-otp-28-slim` | git, build-essential, curl, Hex + Rebar | `arilearn-phx` `ci.yml` |
| `ghcr.io/aretecp/ci-python-uv:3.12` | `ghcr.io/astral-sh/uv:python3.12-bookworm-slim` | git, build-essential, libpq5, chromium | `areteos-py` `ci.yml` (backend) |
| `ghcr.io/aretecp/ci-python:3.12` | `python:3.12-slim` | git, curl, uv | `beacon` `ci.yml` |
| `ghcr.io/aretecp/ci-node:22` | `node:22-slim` | git, ca-certificates | `areteos-py` `ci.yml` (frontend) |
| `ghcr.io/aretecp/ci-rust-tauri:1.97` | `rust:1.97-slim-bookworm` | git, pkg-config, build-essential, WebKitGTK 4.1 / GTK 3 / libsoup 3 / JSC 4.1 / OpenSSL / Ayatana app-indicator dev packages, clippy, rustfmt | `areteos` `desktop-ci.yml` |

Usage is a one-line swap in the consuming workflow, and the `Install OS
prereqs` step is deleted:

```yaml
container:
  image: ghcr.io/aretecp/ci-elixir:1.18.4-otp-27
```

The packages are public, so no `container.credentials` block is needed.

## What belongs in an image

**Yes:** OS packages, language toolchains, package-manager bootstrap
(Hex/Rebar, uv), toolchain components (clippy, rustfmt). Things that change
when *the toolchain* changes.

**No:** anything version-coupled to application source — `node_modules`, `mix`
deps, Playwright browser binaries, Python virtualenvs. Those belong in the
consuming workflow behind `actions/cache`, keyed on the repo's lockfile. Bake
them here and the image silently goes stale against the repo that depends on
it, which is a worse failure than a slow step: it is a *wrong* step.

## Tags

Each image gets two:

- `<tag>` — moving. What consumers pin. Encodes the toolchain contract
  (`1.18.4-otp-27`) and picks up OS security patches on the weekly rebuild.
- `<tag>-<yyyymmdd>-<sha7>` — immutable. For bisecting a bad refresh or
  pinning strictly.

This mirrors the repo's `@v1` convention: the moving tag names the contract,
not the build.

## Adding or changing an image

1. Add `images/<dir>/Dockerfile`.
2. Add `images/<dir>/smoke.sh` — assert *every* tool the consuming workflow
   stopped installing. This runs on each build; a missing package is a red PR
   check instead of six repos failing their next run.
3. Add an entry to [`manifest.json`](manifest.json) (`dir`, `image`, `tag`,
   `consumers`). The build matrix reads it — no workflow edit needed.
4. Open a PR. It builds and smoke-tests without publishing; merging to `main`
   publishes.

Bumping a toolchain version means a new `tag` (and usually a new `dir`), then a
follow-up PR in each consumer. Do not mutate a tag's meaning — `1.18.4-otp-27`
must always be Elixir 1.18.4 on OTP 27.

## `force-unsafe-io`

Every Dockerfile starts by disabling `dpkg`'s per-file fsync:

```dockerfile
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup
```

A build layer is discarded wholesale if the build crashes, so the durability
`dpkg` is buying does not exist here. The same line is worth adding to any
`apt-get` that survives in a consuming workflow (Playwright's `--with-deps`,
for instance) for the same reason: the container is thrown away either way.
