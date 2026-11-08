-- Pinned-uv install test. Run from the plugin root:
--   XDG_DATA_HOME=<fresh dir> nvim --headless -u NONE --cmd 'set rtp+=.' \
--     -l test/pinned.lua
-- PINNED_SCENARIO=mismatch makes the fake sha256sum report a wrong hash.
-- PINNED_SCENARIO=eexist pre-creates the uv dir, the residue of an
-- interrupted extract: the pinned install must still complete.
-- No network: fake curl, tar, sha256sum and uv binaries log their argv
-- under $XDG_DATA_HOME/fakelog. Exits non-zero on failure.

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ':p')
local datahome = vim.fn.stdpath('data')
local data = datahome .. '/simdref'
local scenario = os.getenv('PINNED_SCENARIO') or 'match'
local fakelog = datahome .. '/fakelog'
local fakebin = datahome .. '/fakebin'

local function fail(msg)
  io.stderr:write('FAIL: ' .. msg .. '\n')
  os.exit(1)
end

if scenario == 'eexist' then
  -- The interrupted-extract residue: data_dir/uv already exists, empty.
  vim.fn.mkdir(data .. '/uv', 'p')
else
  if vim.uv.fs_stat(data) ~= nil then
    fail('use a fresh XDG_DATA_HOME (..../simdref must not exist)')
  end
end

local function writef(path, content)
  local fh = io.open(path, 'w')
  if not fh then
    fail('cannot write ' .. path)
  end
  fh:write(content)
  fh:close()
  local fd = vim.uv.fs_open(path, 'r', 0)
  if not fd then
    fail('cannot chmod ' .. path)
  end
  vim.uv.fs_fchmod(fd, 493) -- 0o755
  vim.uv.fs_close(fd)
end

vim.fn.mkdir(fakebin, 'p')
vim.fn.mkdir(fakelog, 'p')

writef(fakebin .. '/curl', [[#!/bin/sh
PATH="/usr/bin:/bin"; export PATH
echo "curl $*" >> "$FAKELOG/curl.txt"
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
printf 'fake uv archive' > "$out"
exit 0
]])
-- Reports the wrong hash when $FAKELOG/mismatch exists, else extracts the
-- pinned hash of this machine's triple from the plugin source.
writef(fakebin .. '/sha256sum', [[#!/bin/sh
PATH="/usr/bin:/bin"; export PATH
echo "sha256sum $*" >> "$FAKELOG/sha256sum.txt"
if [ -f "$FAKELOG/mismatch" ]; then
  echo "0000000000000000000000000000000000000000000000000000000000000000  $1"
  exit 0
fi
t="x86_64-unknown-linux-gnu"
[ "$(uname -m)" = "aarch64" ] && t="aarch64-unknown-linux-gnu"
h=$(grep -F "$t" "$REPO/plugin/simdref.lua" | grep -oE "[0-9a-f]{64}" | head -1)
echo "$h  $1"
]])
-- Writes the extracted uv binary, which logs argv and creates the tool
-- shims when it runs `tool install simdref`.
writef(fakebin .. '/tar', [[#!/bin/sh
PATH="/usr/bin:/bin"; export PATH
echo "tar $*" >> "$FAKELOG/tar.txt"
dir=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then dir="$a"; fi
  prev="$a"
done
mkdir -p "$dir"
cat > "$dir/uv" <<'EOF'
#!/bin/sh
PATH="/usr/bin:/bin"; export PATH
echo "uv $*" >> "$FAKELOG/uv.txt"
if [ "$1" = "tool" ] && [ "$2" = "install" ]; then
  mkdir -p "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$UV_TOOL_BIN_DIR/simdref-lsp"
  chmod +x "$UV_TOOL_BIN_DIR/simdref-lsp"
  printf '#!/bin/sh\necho "isa $*" >> "$FAKELOG/isa.txt"\nexit 0\n' > "$UV_TOOL_BIN_DIR/isa"
  chmod +x "$UV_TOOL_BIN_DIR/isa"
fi
exit 0
EOF
chmod +x "$dir/uv"
exit 0
]])
-- System uv, only used when the pinned path falls back.
writef(fakebin .. '/uv', [[#!/bin/sh
PATH="/usr/bin:/bin"; export PATH
echo "sysuv $*" >> "$FAKELOG/sysuv.txt"
if [ "$1" = "tool" ] && [ "$2" = "install" ]; then
  mkdir -p "$UV_TOOL_DIR" "$UV_TOOL_BIN_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$UV_TOOL_BIN_DIR/simdref-lsp"
  chmod +x "$UV_TOOL_BIN_DIR/simdref-lsp"
  printf '#!/bin/sh\necho "sysisa $*" >> "$FAKELOG/sysisa.txt"\nexit 0\n' > "$UV_TOOL_BIN_DIR/isa"
  chmod +x "$UV_TOOL_BIN_DIR/isa"
fi
exit 0
]])

-- The fakes inherit FAKELOG and REPO from the nvim process env.
vim.fn.setenv('FAKELOG', fakelog)
vim.fn.setenv('REPO', root)
vim.fn.setenv('PATH', fakebin)
if scenario == 'mismatch' then
  writef(fakelog .. '/mismatch', '')
end

-- An install failure surfaces as a WARN notify; capture it.
local warned = false
vim.notify = function(_, level)
  if level == vim.log.levels.WARN then
    warned = true
  end
end

vim.cmd('runtime! plugin/simdref.lua')

local server = data .. '/bin/simdref-lsp'
local ok = vim.wait(60000, function()
  return vim.uv.fs_stat(server) ~= nil
end, 100)
if not ok then
  fail('install did not produce ' .. server)
end
-- The isa update runs after the uv job callback; the server file appears
-- before it, so wait for its log instead of assuming it already ran.
local function log_exists(name)
  return vim.uv.fs_stat(fakelog .. '/' .. name) ~= nil
end
local which = (scenario == 'match' or scenario == 'eexist') and 'isa.txt' or 'sysisa.txt'
ok = vim.wait(15000, function()
  return log_exists(which)
end, 50)
if not ok then
  fail(which .. ' never appeared after the server')
end
if warned then
  fail('install surfaced a WARN notify')
end

local function readf(path)
  local fh = io.open(path, 'r')
  if not fh then
    return nil
  end
  local s = fh:read('*a')
  fh:close()
  return s
end

-- CI and the container are linux; the fake sha256sum resolves the same way.
local m = vim.uv.os_uname().machine:lower()
local arch = (m == 'aarch64' or m == 'arm64') and 'aarch64' or 'x86_64'
local url = 'https://github.com/astral-sh/uv/releases/download/0.12.23/uv-' .. arch
  .. '-unknown-linux-gnu.tar.gz'

if scenario == 'match' or scenario == 'eexist' then
  local curl_log = readf(fakelog .. '/curl.txt')
  if curl_log == nil or curl_log:find(url, 1, true) == nil then
    fail('curl did not fetch the pinned url, log: ' .. tostring(curl_log))
  end
  if readf(fakelog .. '/sha256sum.txt') == nil then
    fail('the archive sha256 was never checked')
  end
  if readf(fakelog .. '/tar.txt') == nil then
    fail('the verified archive was never extracted')
  end
  local uv_log = readf(fakelog .. '/uv.txt')
  if uv_log == nil or uv_log:find('tool install simdref', 1, true) == nil then
    fail('the downloaded uv did not run tool install, log: ' .. tostring(uv_log))
  end
  if readf(fakelog .. '/isa.txt') == nil then
    fail('isa update did not run')
  end
  if readf(fakelog .. '/sysuv.txt') ~= nil then
    fail('system uv was used although the pinned download succeeded')
  end
else
  if readf(fakelog .. '/tar.txt') ~= nil then
    fail('a checksum-mismatched archive was extracted')
  end
  if readf(fakelog .. '/uv.txt') ~= nil then
    fail('the checksum-mismatched uv was used')
  end
  local sys_log = readf(fakelog .. '/sysuv.txt')
  if sys_log == nil or sys_log:find('tool install simdref', 1, true) == nil then
    fail('system uv fallback did not run tool install, log: ' .. tostring(sys_log))
  end
end
print('PASS: pinned-uv install (' .. scenario .. ') produced ' .. server)
os.exit(0)
