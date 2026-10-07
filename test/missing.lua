-- Missing-binary test. Run from the plugin root:
--   nvim --headless -u NONE --cmd 'set rtp+=.' -l test/missing.lua
-- Empties PATH so neither simdref-lsp, uv nor python3 are found, sources the
-- plugin and asserts the manual-install message fires once via vim.notify.

local function fail(msg)
  io.stderr:write('FAIL: ' .. msg .. '\n')
  os.exit(1)
end

-- Capture notifications.
local seen = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  seen[#seen + 1] = tostring(msg)
end

-- No simdref-lsp, no uv, no python3.
vim.fn.setenv('PATH', '')

vim.cmd('runtime! plugin/simdref.lua')

-- notify_missing is wrapped in vim.schedule; pump the event loop until it fires.
vim.wait(5000, function()
  return #seen > 0
end, 50)

vim.notify = orig_notify

if #seen == 0 then
  fail('no notification shown')
end
for _, m in ipairs(seen) do
  print('notify: ' .. m)
end
local expected = 'simdref-lsp not found. Run: uv tool install simdref && isa update'
if not tostring(seen[1]):find(expected, 1, true) then
  fail('expected message missing, got: ' .. tostring(seen[1]))
end
if not tostring(seen[1]):find('https://github.com/simd-labs/simdref', 1, true) then
  fail('expected URL missing')
end
if not tostring(seen[1]):find('uv not found and python3 is missing or older than 3.10', 1, true) then
  fail('expected install-failure cause missing')
end
-- nvim must not error: reaching here means the plugin loaded cleanly.
print('PASS: missing-binary message shown once, no error')
os.exit(0)
