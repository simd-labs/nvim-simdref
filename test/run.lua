-- Headless test for nvim-simdref. Run from the plugin root:
--   nvim --headless -u NONE --cmd 'set rtp+=.' -l test/run.lua
-- simdref-lsp must be on PATH and SIMDREF_CATALOG must point at a catalog.db.
-- Exits non-zero on failure.

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ':p')
local fixture = root .. '/test/fixtures/add.s'

vim.cmd('filetype on')

local function fail(msg)
  io.stderr:write('FAIL: ' .. msg .. '\n')
  os.exit(1)
end

-- Source the shipped plugin. simdref-lsp is on PATH so server_cmd() resolves
-- it and the plugin calls vim.lsp.enable('simdref') reading lsp/simdref.lua.
vim.cmd('runtime! plugin/simdref.lua')

local expected = 'Add Packed Single Precision Floating-Point Values'

vim.cmd.edit(vim.fn.fnameescape(fixture))
local buf = vim.api.nvim_get_current_buf()
if vim.bo[buf].filetype ~= 'asm' then
  fail('expected filetype asm for .s, got ' .. vim.bo[buf].filetype)
end

-- Wait for the client to attach to this buffer.
local ok = vim.wait(10000, function()
  return #vim.lsp.get_clients({ bufnr = buf, name = 'simdref' }) > 0
end, 100)
if not ok then
  fail('simdref client did not attach')
end

-- Inlay hints must be enabled for this buffer by the plugin autocmd.
if not vim.lsp.inlay_hint.is_enabled({ bufnr = buf }) then
  fail('inlay hints not enabled for buffer')
end

-- Wait for hints to arrive, then read them.
local hints = {}
ok = vim.wait(10000, function()
  hints = vim.lsp.inlay_hint.get({ bufnr = buf })
  return #hints > 0
end, 200)
if not ok then
  fail('no inlay hints returned')
end

-- Find the vaddps line (0-based line 3) and assert its label.
local target = nil
for _, h in ipairs(hints) do
  local pos = h.inlay_hint.position
  if pos.line == 3 then
    target = h.inlay_hint.label
    break
  end
end
if not target then
  local got = {}
  for _, h in ipairs(hints) do
    got[#got + 1] = string.format('line %d: %s', h.inlay_hint.position.line, tostring(h.inlay_hint.label))
  end
  fail('no hint on vaddps line 3. Hints: ' .. table.concat(got, ' | '))
end
if type(target) == 'table' then
  -- label can be InlayHintLabelPart[]
  local parts = {}
  for _, p in ipairs(target) do
    parts[#parts + 1] = p.value
  end
  target = table.concat(parts)
end
if not target:find(expected, 1, true) then
  fail(string.format('vaddps label %q does not contain %q', target, expected))
end
print('PASS: vaddps (.s) -> ' .. target)

-- Check inline asm in a C++ buffer attaches and gets the same hint.
local cpp = root .. '/test/fixtures/inline.cpp'
vim.cmd.edit(vim.fn.fnameescape(cpp))
local cbuf = vim.api.nvim_get_current_buf()
if vim.bo[cbuf].filetype ~= 'cpp' then
  fail('expected filetype cpp for .cpp, got ' .. vim.bo[cbuf].filetype)
end
ok = vim.wait(10000, function()
  return #vim.lsp.get_clients({ bufnr = cbuf, name = 'simdref' }) > 0
end, 100)
if not ok then
  fail('simdref client did not attach to cpp buffer')
end
local chints = {}
ok = vim.wait(10000, function()
  chints = vim.lsp.inlay_hint.get({ bufnr = cbuf })
  return #chints > 0
end, 200)
if not ok then
  fail('no inlay hints returned for cpp buffer')
end
local clabel = nil
for _, h in ipairs(chints) do
  local lbl = h.inlay_hint.label
  if type(lbl) == 'table' then
    local parts = {}
    for _, p in ipairs(lbl) do
      parts[#parts + 1] = p.value
    end
    lbl = table.concat(parts)
  end
  if type(lbl) == 'string' and lbl:find(expected, 1, true) then
    clabel = lbl
    break
  end
end
if not clabel then
  local got = {}
  for _, h in ipairs(chints) do
    got[#got + 1] = string.format('line %d: %s', h.inlay_hint.position.line, tostring(h.inlay_hint.label))
  end
  fail('no vaddps hint in cpp buffer. Hints: ' .. table.concat(got, ' | '))
end
print('PASS: vaddps (.cpp inline asm) -> ' .. clabel)
os.exit(0)
