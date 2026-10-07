#!/usr/bin/env bash
# Runs the nvim-simdref tests inside the container. Mounted at /src.
set -u
cd "$(dirname "$0")/../.." || exit 1

echo "nvim: $(nvim --version | head -1)"
echo "python3: $(python3 --version 2>&1)"
echo "uv: $(command -v uv || echo none)"
echo "simdref-lsp on PATH: $(command -v simdref-lsp || echo none)"

fail=0

echo "--- hint test ---"
free -g | head -1
python3 -m venv /tmp/home/hint-venv
/tmp/home/hint-venv/bin/pip install -q simdref==0.0.8
HOME=/tmp/home /tmp/home/hint-venv/bin/isa update >/tmp/home/isa.log 2>&1
if [ ! -f /tmp/home/.local/share/simdref/catalog.db ]; then
  echo "isa update did not produce a catalog"; tail -5 /tmp/home/isa.log; fail=1
else
  env PATH="/tmp/home/hint-venv/bin:/usr/local/bin:/usr/bin:/bin" HOME=/tmp/home \
    nvim --headless -u NONE --cmd 'set rtp+=.' -l test/run.lua
  [ $? -ne 0 ] && fail=1
fi

echo "--- venv fallback test (no uv, no simdref-lsp on PATH) ---"
free -g | head -1
rm -rf /tmp/home/fb
mkdir -p /tmp/home/fb
# /usr/bin:/bin only: python3 present, no uv (uv is in /usr/local/bin), no simdref-lsp.
env PATH="/usr/bin:/bin" XDG_DATA_HOME=/tmp/home/fb HOME=/tmp/home \
  nvim --headless -u NONE --cmd 'set rtp+=.' -l test/fallback.lua
[ $? -ne 0 ] && fail=1

echo "--- missing-binary test (no uv, no python3) ---"
free -g | head -1
rm -rf /tmp/home/mb
mkdir -p /tmp/home/mb
env XDG_DATA_HOME=/tmp/home/mb HOME=/tmp/home \
  nvim --headless -u NONE --cmd 'set rtp+=.' -l test/missing.lua
[ $? -ne 0 ] && fail=1

echo "=== container tests done, fail=$fail ==="
exit $fail
