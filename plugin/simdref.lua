local data_dir = vim.fn.stdpath('data') .. '/simdref'
local is_win = vim.fn.has('win32') == 1
local bin_dir = data_dir .. '/bin'
local venv_bin = data_dir .. (is_win and '/venv/Scripts' or '/venv/bin')
local exe = is_win and '.exe' or ''

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function on_path(name)
  return vim.fn.executable(name) == 1
end

-- Resolve the server command: PATH first, then the private install dir.
local function server_cmd()
  if on_path('simdref-lsp') then
    return { 'simdref-lsp' }
  end
  local uv_bin = bin_dir .. '/simdref-lsp' .. exe
  if exists(uv_bin) then
    return { uv_bin }
  end
  local venv_bin_path = venv_bin .. '/simdref-lsp' .. exe
  if exists(venv_bin_path) then
    return { venv_bin_path }
  end
  return nil
end

local function enable(cmd)
  vim.lsp.config('simdref', { cmd = cmd })
  vim.lsp.enable('simdref')
end

local installed = false
local function notify_missing(cause)
  if installed then
    return
  end
  installed = true
  local msg = 'simdref-lsp not found. Run: uv tool install simdref && isa update\n'
    .. 'https://github.com/simd-labs/simdref'
  if cause then
    msg = msg .. '\n' .. cause
  end
  vim.notify(msg, vim.log.levels.WARN, { title = 'simdref' })
end

local function python_ok()
  if not on_path('python3') then
    return false
  end
  local out = vim.system({ 'python3', '-c', 'import sys;print(sys.version_info>=(3,10))' }):wait()
  return out.code == 0 and out.stdout:match('True') ~= nil
end

local function start_after_install(bin)
  installed = true
  enable({ bin })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.lsp.enable('simdref', { bufnr = buf })
    end
  end
end

local function install()
  if vim.g.simdref_installing then
    return
  end
  vim.g.simdref_installing = true
  if on_path('uv') then
    local env = { UV_TOOL_DIR = data_dir .. '/tools', UV_TOOL_BIN_DIR = bin_dir }
    vim.system({ 'uv', 'tool', 'install', 'simdref' }, { env = env, text = true }, function(r)
      if r.code ~= 0 then
        vim.schedule(function()
          notify_missing('uv tool install failed: ' .. (r.stderr or ''))
        end)
        return
      end
      vim.system({ bin_dir .. '/isa' .. exe, 'update' }, { text = true }, function(r2)
        vim.schedule(function()
          if r2.code ~= 0 then
            notify_missing('isa update failed: ' .. (r2.stderr or ''))
          else
            start_after_install(bin_dir .. '/simdref-lsp' .. exe)
          end
        end)
      end)
    end)
    return
  end
  if python_ok() then
    vim.system({ 'python3', '-m', 'venv', data_dir .. '/venv' }, { text = true }, function(rv)
      if rv.code ~= 0 then
        vim.schedule(function()
          notify_missing('python3 -m venv failed: ' .. (rv.stderr or ''))
        end)
        return
      end
      local pip = venv_bin .. '/pip' .. exe
      vim.system({ pip, 'install', 'simdref' }, { text = true }, function(rp)
        if rp.code ~= 0 then
          vim.schedule(function()
            notify_missing('pip install simdref failed: ' .. (rp.stderr or ''))
          end)
          return
        end
        vim.system({ venv_bin .. '/isa' .. exe, 'update' }, { text = true }, function(ru)
          vim.schedule(function()
            if ru.code ~= 0 then
              notify_missing('isa update failed: ' .. (ru.stderr or ''))
            else
              start_after_install(venv_bin .. '/simdref-lsp' .. exe)
            end
          end)
        end)
      end)
    end)
    return
  end
  vim.schedule(function()
    notify_missing('uv not found and python3 is missing or older than 3.10')
  end)
end

if not vim.g.simdref_disable then
  local cmd = server_cmd()
  if cmd then
    enable(cmd)
    installed = true
  else
    install()
  end
end

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and client.name == 'simdref' then
      vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
    end
  end,
})
