-- Venv-fallback test. Launch with:
--   PATH=/usr/bin XDG_DATA_HOME=<scratch>/data nvim --headless -u NONE \
--     --cmd 'set rtp+=.' -l test/fallback.lua
-- The PATH has python3 but no uv and no simdref-lsp, so the plugin must build
-- a venv in stdpath('data')/simdref, install simdref and serve hints.
-- Network is required. Exits non-zero on failure.

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ':p')
local fixture = root .. '/test/fixtures/add.s'
local data = vim.fn.stdpath('data') .. '/simdref'
local server = data .. '/venv/bin/simdref-lsp'
-- The simdref server reads its catalog from its own XDG_DATA_HOME/simdref
-- dir, a sibling of the nvim data dir, not from the plugin's private dir.
local catalog = (os.getenv('XDG_DATA_HOME') or (vim.fn.expand('~/.local/share')))
  .. '/simdref/catalog.db'

vim.cmd('filetype on')

local function fail(msg)
  io.stderr:write('FAIL: ' .. msg .. '\n')
  os.exit(1)
end

-- Count the install commands sent to vim.system.
local install_count = 0
local real_system = vim.system
vim.system = function(cmd, opts, cb)
  local s = table.concat(cmd, ' ')
  if s:find('install simdref', 1, true) or s:find('tool install', 1, true) then
    install_count = install_count + 1
  end
  return real_system(cmd, opts, cb)
end

-- No server binary must exist yet.
if vim.uv.fs_stat(server) then
  fail(server .. ' already exists; use a fresh XDG_DATA_HOME')
end

-- Source the shipped plugin: it must start the venv install in the background.
vim.cmd('runtime! plugin/simdref.lua')

-- Open two asm buffers while the install runs. Re-source the plugin for the
-- second buffer: the flag must stop the second install into the same dir.
vim.cmd.edit(vim.fn.fnameescape(fixture))
local buf1 = vim.api.nvim_get_current_buf()
vim.cmd('enew')
local buf2 = vim.api.nvim_get_current_buf()
vim.bo[buf2].filetype = 'asm'
vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { 'vaddps %xmm0, %xmm1, %xmm2' })
vim.cmd('runtime! plugin/simdref.lua')
vim.cmd.buffer(buf1)

-- pip install produces the server binary.
local ok = vim.wait(300000, function()
  return vim.uv.fs_stat(server) ~= nil
end, 1000)
if not ok then
  fail('venv install did not produce ' .. server)
end
print('PASS: venv install produced ' .. server)

if install_count ~= 1 then
  fail('install command ran ' .. install_count .. ' times, expected 1')
end
print('PASS: install ran exactly once')

-- isa update writes the catalog the server reads, then the plugin starts the
-- server. Wait for the catalog to be fully written (the download is the slow
-- part), then attach.
ok = vim.wait(300000, function()
  return vim.uv.fs_stat(catalog) ~= nil
end, 1000)
if not ok then
  fail('no catalog.db at ' .. catalog)
end
print('PASS: catalog at ' .. catalog)

-- The plugin starts the server only after isa update exits. Give the attach
-- the rest of the budget.
vim.cmd.buffer(buf1)
ok = vim.wait(300000, function()
  return #vim.lsp.get_clients({ bufnr = buf1, name = 'simdref' }) > 0
end, 500)
if not ok then
  fail('simdref client did not attach after venv install')
end
local expected = 'Add Packed Single Precision Floating-Point Values'

local function has_vaddps_hint(buf)
  local hints = {}
  local hok = vim.wait(20000, function()
    hints = vim.lsp.inlay_hint.get({ bufnr = buf })
    return #hints > 0
  end, 200)
  if not hok then
    return false
  end
  for _, h in ipairs(hints) do
    local lbl = h.inlay_hint.label
    if type(lbl) == 'string' and lbl:find(expected, 1, true) then
      return true
    end
  end
  return false
end

if not has_vaddps_hint(buf1) then
  fail('no vaddps hint in buffer 1 after venv install')
end
print('PASS: buffer 1 has vaddps hint')

if not has_vaddps_hint(buf2) then
  fail('no vaddps hint in buffer 2 after venv install')
end
print('PASS: buffer 2 has vaddps hint')
os.exit(0)
