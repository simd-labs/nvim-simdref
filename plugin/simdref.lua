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

local function touch(path)
  local fd = vim.uv.fs_open(path, 'w', 420) -- 0644
  if fd then
    vim.uv.fs_close(fd)
    return true
  end
  return false
end

local function notify_debug(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.DEBUG, { title = 'simdref' })
  end)
end

-- Every vim.system gets a 10 min timeout; a stuck uv or isa must not hang
-- the update path forever.
local TIMEOUT_MS = 10 * 60 * 1000

local function read_isa_version(isa, env, cb)
  vim.system({ isa, '--version' }, { env = env, text = true, timeout = TIMEOUT_MS }, function(r)
    if r.code == 0 and r.stdout then
      cb((r.stdout:gsub('%s+$', '')))
    else
      cb(nil)
    end
  end)
end

local lock_path
local function lock_release()
  if lock_path then
    vim.uv.fs_unlink(lock_path)
    lock_path = nil
  end
end

-- Share one lock with the other editor extensions: two uv processes on one
-- tool dir corrupt the venv. Exclusive create; a fresh lock (< 30 min) means
-- another extension holds it, a stale one is taken over. Always removed.
local LOCK_STALE = 30 * 60
local function lock_acquire(dir)
  local path = dir .. '/update.lock'
  local st = vim.uv.fs_stat(path)
  if st then
    if (os.time() - st.mtime.sec) < LOCK_STALE then
      return false
    end
    vim.uv.fs_unlink(path)
  end
  local fd = vim.uv.fs_open(path, 'wx', 420) -- 0644
  if not fd then
    return false
  end
  vim.uv.fs_close(fd)
  lock_path = path
  return true
end

-- `isa vaddps --short` runs ensure_runtime(); when the version did not
-- change this costs ~0.4 s and downloads nothing. Runs only when
-- server_cmd() resolved the private copy, so a PATH simdref is never touched.
local function auto_update()
  if vim.g.simdref_auto_updated then
    return
  end
  vim.g.simdref_auto_updated = true
  local uv_path = on_path('uv')
    and exists(bin_dir .. '/isa' .. exe)
    and exists(data_dir .. '/tools/simdref')
  local pip_path = (not uv_path) and exists(venv_bin .. '/isa' .. exe)
  if not uv_path and not pip_path then
    return
  end
  local isa = uv_path and (bin_dir .. '/isa' .. exe) or (venv_bin .. '/isa' .. exe)
  local env = uv_path and { UV_TOOL_DIR = data_dir .. '/tools', UV_TOOL_BIN_DIR = bin_dir }
    or nil
  local upgrade = uv_path and { 'uv', 'tool', 'upgrade', 'simdref' }
    or { venv_bin .. '/pip' .. exe, 'install', '-U', 'simdref' }
  if not lock_acquire(data_dir) then
    return
  end
  local stamp = data_dir .. '/last-update-check'
  local st = vim.uv.fs_stat(stamp)
  if st and (os.time() - st.mtime.sec) < 24 * 3600 then
    lock_release()
    return
  end
  if not touch(stamp) then
    lock_release()
    notify_debug('simdref auto-update: cannot write ' .. stamp)
    return
  end
  read_isa_version(isa, env, function(before)
    -- before may be nil (unreadable); the check still runs.
    vim.system(upgrade, { env = env, text = true, timeout = TIMEOUT_MS }, function(r)
      if r.code ~= 0 then
        notify_debug('simdref auto-update failed: ' .. (r.stderr or ''))
      end
      -- The refresh always runs, also when the upgrade failed: an offline
      -- upgrade must not block repairing a catalog.
      vim.system({ isa, 'vaddps', '--short' }, { env = env, text = true, timeout = TIMEOUT_MS }, function(r2)
        if r2.code ~= 0 then
          notify_debug('simdref catalog refresh failed: ' .. (r2.stderr or ''))
        end
        read_isa_version(isa, env, function(after)
          lock_release()
          if not after or after == before then
            return
          end
          vim.schedule(function()
            local clients = vim.lsp.get_clients({ name = 'simdref' })
            for _, c in ipairs(clients) do
              c:stop()
            end
            -- Wait for the stopped clients to exit, bounded at 10 s.
            vim.wait(10000, function()
              for _, c in ipairs(clients) do
                if not c:is_stopped() then
                  return false
                end
              end
              return true
            end, 100)
            vim.cmd.doautoall('nvim.lsp.enable FileType')
          end)
        end)
      end)
    end)
  end)
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
    if cmd[1] ~= 'simdref-lsp' then
      auto_update()
    end
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
