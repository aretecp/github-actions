# Asserts every tool the consuming workflow (areteos/ci.yml) stopped installing.
elixir --version
git --version
mix hex.info > /dev/null && echo "hex: ok"
mix help local.rebar > /dev/null && echo "rebar: ok"
cc --version | head -1
unzip -v | head -1
python3 --version
uv --version
# The managed 3.12 must resolve from the shared install dir, not from $HOME.
uv python find 3.12
