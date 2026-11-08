-- Visual driver for the .cpp screenshot. Runs inside xterm under Xvfb.
-- Writes /tmp/ready-hints when the hint text is on screen, waits for
-- /tmp/do-hover, hovers inside the asm string, writes /tmp/ready-hover.
-- Event-driven (vim.defer_fn polling): a blocking vim.wait over the capture
-- window keeps the main loop from running its redraw pass, so the TUI
-- screen stays frozen at its last computed state.
local expected = 'Add Packed Single Precision Floating-Point Values'

local function fail(msg)
  io.stderr:write('SHOT FAIL: ' .. msg .. '\n')
  os.exit(1)
end

local function writeflag(f)
  local fh = io.open(f, 'w')
  if fh then fh:close() end
end

vim.cmd('filetype on')
-- -u NONE loads no runtime plugins, so g:syntax_on stays nil and the LSP
-- hover float skips markdown rendering (raw ``` ** ## on screen).
vim.cmd('syntax on')
vim.cmd('set rtp+=/src')
vim.cmd('runtime! plugin/simdref.lua')

vim.schedule(function()
  vim.cmd.edit(vim.fn.fnameescape('/fixtures/test.cpp'))
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= 'cpp' then
    fail('filetype is ' .. vim.bo[buf].filetype)
  end

  local function has_hint()
    for _, h in ipairs(vim.lsp.inlay_hint.get({ bufnr = buf })) do
      local lbl = h.inlay_hint.label
      if type(lbl) == 'string' and lbl:find(expected, 1, true) then
        return true
      end
    end
    return false
  end

  local function has_float()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local conf = vim.api.nvim_win_get_config(w)
      if type(conf.relative) == 'string' and #conf.relative > 0 then
        local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, true), '\n')
        if text:find('Add Packed Single', 1, true) then return true end
      end
    end
    return false
  end

  local t_phase = vim.uv.now()
  local last_arm = vim.uv.now()

  -- forward-declared so the mutually recursive ticks see each other
  local attach_tick, hints_tick, hoverfile_tick, float_tick

  attach_tick = function()
    if #vim.lsp.get_clients({ bufnr = buf, name = 'simdref' }) > 0 then
      t_phase = vim.uv.now()
      hints_tick()
    elseif vim.uv.now() - t_phase > 120000 then
      fail('simdref client did not attach to cpp buffer')
    else
      vim.defer_fn(attach_tick, 200)
    end
  end

  hints_tick = function()
    if has_hint() then
      writeflag('/tmp/ready-hints')
      t_phase = vim.uv.now()
      hoverfile_tick()
    elseif vim.uv.now() - t_phase > 120000 then
      fail('vaddps hint never appeared in cpp buffer')
    else
      -- Re-arm while waiting: the first inlayHint request can race didOpen,
      -- and the server then answers from an empty document with no retry.
      if vim.uv.now() - last_arm > 2000 then
        last_arm = vim.uv.now()
        vim.lsp.inlay_hint.enable(true, { bufnr = buf })
      end
      vim.defer_fn(hints_tick, 200)
    end
  end

  hoverfile_tick = function()
    if vim.uv.fs_stat('/tmp/do-hover') ~= nil then
      -- vaddps inside the asm string: line 2, column 18 (0-based) is the 'v'.
      vim.api.nvim_win_set_cursor(0, { 2, 18 })
      -- max_width keeps the float left-anchored with a right margin, so
      -- long lines wrap inside the float instead of at the terminal edge.
      vim.lsp.buf.hover({ max_width = 118 })
      t_phase = vim.uv.now()
      float_tick()
    elseif vim.uv.now() - t_phase > 120000 then
      fail('no hover trigger')
    else
      vim.defer_fn(hoverfile_tick, 200)
    end
  end

  float_tick = function()
    if has_float() then
      writeflag('/tmp/ready-hover')
      -- hold the frame so the capture lands on it
      vim.defer_fn(function() os.exit(0) end, 1500)
    elseif vim.uv.now() - t_phase > 60000 then
      fail('hover float never appeared in cpp buffer')
    else
      vim.defer_fn(float_tick, 200)
    end
  end

  attach_tick()
end)
