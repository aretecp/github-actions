# Asserts every tool the consuming workflow (areteos/ci.yml) stopped installing.
elixir --version
git --version
# Hex must be a LOADABLE archive, not merely a known task name. This is the
# assertion that catches a MIX_HOME regression: it fails under the Actions
# HOME=/github/home if the archive was baked into the image's own home dir.
mix hex.info > /dev/null && echo "hex: ok"
# rebar3 must exist on disk. `mix help local.rebar` is NOT a valid check —
# local.rebar is a built-in Mix task, so it passes on a vanilla image where
# rebar was never installed.
ls "${MIX_HOME:?MIX_HOME unset — must be a system path, not \$HOME}"/elixir/*/rebar3
cc --version | head -1
unzip -v | head -1
python3 --version
uv --version
# The managed 3.12 must resolve from the shared install dir, not from $HOME.
uv python find 3.12
