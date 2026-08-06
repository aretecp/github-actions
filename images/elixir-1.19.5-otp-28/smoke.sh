# Asserts every tool the consuming workflow (arilearn-phx/ci.yml) stopped installing.
elixir --version
git --version
mix hex.info > /dev/null && echo "hex: ok"
mix help local.rebar > /dev/null && echo "rebar: ok"
cc --version | head -1
curl --version | head -1
