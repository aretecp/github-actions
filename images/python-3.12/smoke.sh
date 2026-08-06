# Asserts every tool the consuming workflow (beacon/ci.yml) stopped installing.
python --version
uv --version
git --version
curl --version | head -1
