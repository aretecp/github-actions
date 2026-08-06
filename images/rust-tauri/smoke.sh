# Asserts every tool the consuming workflow (areteos/desktop-ci.yml) stopped
# installing.
cargo --version
cargo clippy --version
cargo fmt --version
git --version

# Consumers pin `channel = "stable"` in rust-toolchain.toml, which rustup
# resolves to a different toolchain than the image's pinned default. The
# components must exist there too, or `cargo clippy` re-downloads on every run.
rustup run stable cargo clippy --version
rustup run stable cargo fmt --version

# Every library the Tauri shell links at compile time. pkg-config failing here
# is exactly how the build would fail, only faster and with a clearer message.
pkg-config --modversion \
  webkit2gtk-4.1 \
  javascriptcoregtk-4.1 \
  libsoup-3.0 \
  gtk+-3.0 \
  openssl \
  ayatana-appindicator3-0.1
