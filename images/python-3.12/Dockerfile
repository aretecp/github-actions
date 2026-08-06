# CI base image for plain Python 3.12 backends that drive uv themselves (beacon).
#
# Bakes the "Install OS prereqs" + "Install uv" steps.
FROM python:3.12-slim

# See images/README.md — dpkg's per-file fsync buys nothing in a build layer.
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# System path so uv resolves without a $GITHUB_PATH append in the consumer.
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && uv --version
