# CI base image for the Tauri desktop workspace (areteos/desktop).
#
# Bakes the "Install OS prereqs" + "Add clippy and rustfmt components" steps.
# The WebKitGTK/GTK/libsoup dev packages are the single largest apt install in
# the fleet, and they change only when the Tauri shell's link-time deps change.
FROM rust:1.97-slim-bookworm

# See images/README.md — dpkg's per-file fsync buys nothing in a build layer.
RUN echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/02speedup

# git/ca-certificates/curl -> actions/checkout and crates.io.
# The rest is everything the Tauri shell links at compile time: WebKitGTK 4.1,
# GTK 3, libsoup 3, JavaScriptCoreGTK 4.1, OpenSSL, and the Ayatana
# app-indicator library the tray-icon feature needs.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        pkg-config \
        build-essential \
        libwebkit2gtk-4.1-dev \
        libgtk-3-dev \
        libsoup-3.0-dev \
        libjavascriptcoregtk-4.1-dev \
        libssl-dev \
        libayatana-appindicator3-dev \
    && rm -rf /var/lib/apt/lists/*

# The slim image ships the toolchain without clippy/rustfmt. desktop/
# rust-toolchain.toml pins the `stable` channel, which is what this tag
# bootstraps, so adding the components here targets the same toolchain the
# workspace resolves.
RUN rustup component add clippy rustfmt
