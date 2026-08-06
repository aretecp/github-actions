# CI base image for uv-managed Python 3.12 backends (areteos-py).
#
# Bakes the "Install OS prereqs" step AND retires the apt-archive cache dance
# it needed: chromium is ~hundreds of MB of .debs, so the consuming workflow
# had to keep /var/cache/apt, resolve the candidate version for a cache key,
# and disable docker-clean. Baked into the image, that is all deleted — the
# browser arrives with the image layer.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# See images/README.md — dpkg's per-file fsync buys nothing in a build layer.
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup

# git             -> actions/checkout
# build-essential -> deps without a prebuilt wheel
# libpq5          -> psycopg (pulled in by procrastinate at conftest import;
#                    errors "no pq wrapper available" without it)
# chromium        -> the PDF-render inertness test is the only check that
#                    proves injected markup never reaches the rendered PDF
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        build-essential \
        libpq5 \
        chromium \
    && rm -rf /var/lib/apt/lists/* \
    && chromium --version
