# CI base image for Node 22 frontends (areteos-py frontend).
#
# Bakes the "Install OS prereqs" step.
FROM node:22-slim

# See images/README.md — dpkg's per-file fsync buys nothing in a build layer.
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup

# git -> actions/checkout. ca-certificates -> registry HTTPS.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
