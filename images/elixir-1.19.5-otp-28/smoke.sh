# Asserts every tool the consuming workflow (arilearn-phx/ci.yml) stopped installing.
elixir --version
git --version
# Hex must be a LOADABLE archive, not merely a known task name — this is what
# catches a MIX_HOME regression under the Actions HOME=/github/home.
mix hex.info > /dev/null && echo "hex: ok"
# rebar3 must exist on disk. `mix help local.rebar` is NOT a valid check —
# local.rebar is a built-in Mix task, so it passes on a vanilla image.
ls "${MIX_HOME:?MIX_HOME unset — must be a system path, not \$HOME}"/elixir/*/rebar3
cc --version | head -1
curl --version | head -1
