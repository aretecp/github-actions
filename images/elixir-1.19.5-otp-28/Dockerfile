# CI base image for Elixir 1.19.5 / OTP 28 repos (arilearn-phx).
#
# Bakes the "Install OS prereqs" + "Install Hex + Rebar" steps. Keep the tag in
# sync with the consuming repo's .tool-versions.
FROM elixir:1.19.5-otp-28-slim

# See images/README.md — dpkg's per-file fsync buys nothing in a build layer.
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup

# git -> actions/checkout; build-essential -> native deps like bcrypt_elixir;
# ca-certificates/curl -> HTTPS fetches (hex, tarballs).
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force
