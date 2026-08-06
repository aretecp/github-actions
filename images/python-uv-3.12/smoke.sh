# Asserts every tool the consuming workflow (areteos-py/ci.yml backend) stopped
# installing.
python --version
uv --version
git --version
cc --version | head -1
chromium --version
# psycopg needs the libpq runtime; without it conftest import fails with
# "no pq wrapper available".
test -e /usr/lib/x86_64-linux-gnu/libpq.so.5 && echo "libpq5: ok"
