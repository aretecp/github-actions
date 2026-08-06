# CI base image for Elixir 1.18.4 / OTP 27 repos (areteos).
#
# Bakes the "Install OS prereqs" + "Install uv + Python for tool steps" +
# "Install Hex + Rebar" steps that every run of those workflows otherwise
# repeats. Nothing version-coupled to application source lives here — only
# toolchain and OS packages.
FROM elixir:1.18.4-otp-27-slim

# dpkg fsyncs every unpacked file by default. In a container layer that is
# pure cost: a crash mid-unpack discards the layer anyway. This is also what
# makes the image build itself tolerable on a slow-fsync host.
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup

# git            -> actions/checkout
# build-essential-> native deps (bcrypt_elixir, etc.)
# curl, unzip    -> oven-sh/setup-bun and the uv installer
# python3(-venv) -> the app shells out to python for workflow `python` steps
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        unzip \
        build-essential \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Hex/Rebar are not preinstalled on the hexpm image.
RUN mix local.hex --force && mix local.rebar --force

# uv + a managed interpreter power the generic Python tool/code steps (Tool
# Studio sample runs, workflow `python` steps). Installed to a system path and
# a shared interpreter dir so they resolve regardless of HOME.
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv python install 3.12 \
    && uv --version
