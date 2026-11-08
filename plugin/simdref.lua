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

-- True when the executable exists: a relative name must be on PATH, an
-- absolute path must exist. vim.system raises instead of returning an
-- error when it is missing, so check before every spawn.
local function exe_ok(name)
  if name:find('/') ~= nil or name:find('\\') ~= nil then
    return exists(name)
  end
  return on_path(name)
end

-- Every vim.system gets a 10 min timeout; a stuck uv or isa must not hang
-- the update path forever.
local TIMEOUT_MS = 10 * 60 * 1000

local function notify_debug(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.DEBUG, { title = 'simdref' })
  end)
end

local function fire(cmd, opts, cb)
  -- vim.system raises ENOENT when the executable is missing; a raise escapes
  -- the auto-update and surfaces as an error. pcall it into the DEBUG notify.
  local ok, err = pcall(vim.system, cmd, opts, cb)
  if not ok then
    notify_debug('simdref auto-update spawn failed: ' .. tostring(err))
  end
end

-- Install-path spawn: existence-checked, 10 min timeout, raise pcalled.
local function spawn(cmd, env, cb)
  if not exe_ok(cmd[1]) then
    notify_debug('simdref install spawn failed: missing ' .. cmd[1])
    return
  end
  fire(cmd, { env = env, text = true, timeout = TIMEOUT_MS }, cb)
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
  local msg = 'simdref not found. Install it: uv tool install simdref (or pip install simdref), then run isa update. Instructions: https://github.com/simd-labs/simdref'
  if cause then
    msg = msg .. '\n' .. cause
  end
  vim.notify(msg, vim.log.levels.WARN, { title = 'simdref' })
end

local function python_ok()
  if not on_path('python3') then
    return false
  end
  -- pcall: a raise on a broken python3 must not escape the install path.
  local ok, out = pcall(function()
    return vim.system({ 'python3', '-c', 'import sys;print(sys.version_info>=(3,10))' }, {
      text = true,
      timeout = TIMEOUT_MS,
    }):wait()
  end)
  return ok and out.code == 0 and out.stdout:match('True') ~= nil
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

-- Pinned uv release, the first install path: the plugin downloads it into
-- the private dir and checks the archive against the sha256 pinned here,
-- not against a downloaded sidecar. Bump UV_TAG and the six hashes
-- together.
local UV_TAG = '0.12.23'
local UV_SHA256 = {
  ['x86_64-unknown-linux-gnu'] = '9167d72b3319674b6303c4cbe071854bba13ebdf3d76b1a7cbdc175471fb66d6',
  ['aarch64-unknown-linux-gnu'] = '6524bd338177ed50d035d39354e12545e993bbeba2ecbddf0480c5b3a81d313f',
  ['x86_64-apple-darwin'] = '960da44cb4b73685206ddd250b19e0a117fa41095710c1038f081f5cb613efb4',
  ['aarch64-apple-darwin'] = '50487ae565ccd96e499056b4674d438f4c53170202617b4c759defe0c6a1b544',
  ['x86_64-pc-windows-msvc'] = '75d05de6762778c31ee183398de7dd15093fad0ed90b1f236d8205ea5ec00c90',
  ['aarch64-pc-windows-msvc'] = '13294e232ececbe709c06b74e6ced06f2a225ea5591476685362f22be56a50d5',
}
local uv_bin = data_dir .. '/uv/uv' .. exe

-- Keep every uv write (tools, bin shims, cache) inside the private dir.
local uv_env = {
  UV_TOOL_DIR = data_dir .. '/tools',
  UV_TOOL_BIN_DIR = bin_dir,
  UV_CACHE_DIR = data_dir .. '/cache',
}

-- The uv release triple for this platform, or nil when unknown: no uv
-- build is pinned for it, so the download path is skipped.
local function uv_triple()
  local m = vim.uv.os_uname().machine:lower()
  local arch
  if m == 'aarch64' or m == 'arm64' then
    arch = 'aarch64'
  elseif m == 'x86_64' or m == 'amd64' then
    arch = 'x86_64'
  end
  if not arch then
    return nil
  end
  local osname
  if is_win then
    osname = 'pc-windows-msvc'
  elseif vim.fn.has('mac') == 1 then
    osname = 'apple-darwin'
  else
    osname = 'unknown-linux-gnu'
  end
  return arch .. '-' .. osname
end

local function sha256_tool(path)
  if is_win then
    return { 'certutil', '-hashfile', path, 'SHA256' }
  elseif vim.fn.has('mac') == 1 then
    return { 'shasum', '-a', '256', path }
  end
  return { 'sha256sum', path }
end

-- First 64-hex-char token of the tool output, or nil.
local function sha256_of(out)
  for tok in tostring(out):gmatch('%S+') do
    if #tok == 64 and tok:match('^[0-9a-fA-F]+$') ~= nil then
      return tok:lower()
    end
  end
  return nil
end

-- Download the pinned uv into data_dir/uv. on_done(ok): true when uv_bin
-- exists and its archive matched the pinned sha256.
local function download_uv(triple, on_done)
  if exists(uv_bin) then
    on_done(true)
    return
  end
  local zip = is_win
  local url = 'https://github.com/astral-sh/uv/releases/download/' .. UV_TAG
    .. '/uv-' .. triple .. (zip and '.zip' or '.tar.gz')
  local archive = data_dir .. (zip and '/uv.zip' or '/uv.tar.gz')
  local part = archive .. '.part'
  local function abort()
    pcall(vim.uv.fs_unlink, part)
    pcall(vim.uv.fs_unlink, archive)
    on_done(false)
  end
  local tool = sha256_tool(part)
  -- All three tools must exist, or the chain would die mid-flight with the
  -- callback never called.
  if not exe_ok('curl') or not exe_ok(tool[1]) or not exe_ok('tar') then
    abort()
    return
  end
  -- A fresh data dir does not exist yet; curl -o cannot create the dir.
  vim.fn.mkdir(data_dir, 'p')
  if not exists(data_dir) then
    abort()
    return
  end
  spawn({ 'curl', '-f', '-s', '-L', '-o', part, url }, nil, function(r)
    if r.code ~= 0 or not exists(part) then
      abort()
      return
    end
    spawn(tool, nil, function(rh)
      local got = sha256_of(rh.stdout)
      if got ~= UV_SHA256[triple] then
        notify_debug('uv sha256 mismatch for ' .. triple .. ': got ' .. tostring(got))
        abort()
        return
      end
      -- libuv calls: vim.fn.mkdir/rename are banned in the fast event
      -- context the callback runs in. EEXIST means an interrupted extract
      -- left the dir: reuse it, do not abandon the verified download.
      vim.uv.fs_mkdir(data_dir .. '/uv', 493, function(err)
        if err and not exists(data_dir .. '/uv') then
          abort()
          return
        end
        vim.uv.fs_rename(part, archive, function(err2)
          if err2 then
            abort()
            return
          end
          -- The tar.gz holds uv-<triple>/uv; the zip holds uv.exe at its
          -- root.
          local tar = { 'tar', '-xf', archive, '-C', data_dir .. '/uv' }
          if not zip then
            tar[#tar + 1] = '--strip-components=1'
          end
          spawn(tar, nil, function(rt)
            pcall(vim.uv.fs_unlink, archive)
            on_done(rt.code == 0 and exists(uv_bin) or false)
          end)
        end)
      end)
    end)
  end)
end

-- uv tool install simdref with the given uv, then isa update, then start
-- the server from the private bin dir.
local function uv_install(uv)
  local isa = bin_dir .. '/isa' .. exe
  local server = bin_dir .. '/simdref-lsp' .. exe
  local function fail_install(cause)
    vim.schedule(function()
      notify_missing(cause)
    end)
  end
  if not exe_ok(uv) then
    fail_install('uv not usable: ' .. tostring(uv))
    return
  end
  spawn({ uv, 'tool', 'install', 'simdref' }, uv_env, function(r)
    if r.code ~= 0 then
      fail_install('uv tool install failed: ' .. (r.stderr or ''))
      return
    end
    if not exists(isa) then
      fail_install('isa missing after uv tool install')
      return
    end
    spawn({ isa, 'update' }, uv_env, function(r2)
      vim.schedule(function()
        if r2.code ~= 0 then
          notify_missing('isa update failed: ' .. (r2.stderr or ''))
        elseif exists(server) then
          start_after_install(server)
        else
          notify_missing('simdref-lsp missing after install')
        end
      end)
    end)
  end)
end

local function install_fallback()
  if on_path('uv') then
    uv_install('uv')
    return
  end
  if python_ok() then
    spawn({ 'python3', '-m', 'venv', data_dir .. '/venv' }, nil, function(rv)
      if rv.code ~= 0 then
        vim.schedule(function()
          notify_missing('python3 -m venv failed: ' .. (rv.stderr or ''))
        end)
        return
      end
      local pip = venv_bin .. '/pip' .. exe
      spawn({ pip, 'install', 'simdref' }, nil, function(rp)
        if rp.code ~= 0 then
          vim.schedule(function()
            notify_missing('pip install simdref failed: ' .. (rp.stderr or ''))
          end)
          return
        end
        local isa = venv_bin .. '/isa' .. exe
        spawn({ isa, 'update' }, nil, function(ru)
          vim.schedule(function()
            if ru.code ~= 0 then
              notify_missing('isa update failed: ' .. (ru.stderr or ''))
            elseif exists(venv_bin .. '/simdref-lsp' .. exe) then
              start_after_install(venv_bin .. '/simdref-lsp' .. exe)
            else
              notify_missing('simdref-lsp missing after install')
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

local function install()
  if vim.g.simdref_installing then
    return
  end
  vim.g.simdref_installing = true
  local triple = uv_triple()
  if triple and UV_SHA256[triple] then
    download_uv(triple, function(ok)
      if ok then
        uv_install(uv_bin)
      else
        install_fallback()
      end
    end)
    return
  end
  install_fallback()
end

-- One check per day, gated by an exclusive marker file for today's UTC day.
-- Several editor processes share the private install: only the one that
-- creates the marker runs the check. `isa vaddps --short` runs on every
-- check; when the version did not change this costs ~0.4 s and downloads
-- nothing. Runs only when server_cmd() resolved the private copy, so a
-- PATH simdref is never touched.
local function auto_update()
  if vim.g.simdref_auto_updated then
    return
  end
  vim.g.simdref_auto_updated = true
  local uv = exists(uv_bin) and uv_bin or (on_path('uv') and 'uv' or nil)
  local uv_path = uv ~= nil and exists(bin_dir .. '/isa' .. exe) and exists(data_dir .. '/tools/simdref')
  local pip_path = (not uv_path)
    and exists(venv_bin .. '/isa' .. exe)
    and exists(venv_bin .. '/pip' .. exe)
  if not uv_path and not pip_path then
    return
  end
  local isa = uv_path and (bin_dir .. '/isa' .. exe) or (venv_bin .. '/isa' .. exe)
  local env = uv_path and uv_env or nil
  local upgrade = uv_path and { uv, 'tool', 'upgrade', 'simdref' }
    or { venv_bin .. '/pip' .. exe, 'install', '-U', 'simdref' }
  local today = math.floor(os.time() / 86400)
  local marker = data_dir .. '/update-' .. today
  -- Known race: a check running at midnight UTC can overlap the next
  -- day's, and cleanup can delete another process's new marker. The
  -- overlap is accepted; a lock was tried and reintroduced the race.
  local fd = vim.uv.fs_open(marker, 'wx', 420) -- 0644
  if not fd then
    return
  end
  vim.uv.fs_close(fd)
  -- Delete stale markers of older days; today's marker stays.
  local scan = vim.uv.fs_scandir(data_dir)
  if scan then
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      if name:match('^update%-') and name ~= ('update-' .. today) then
        pcall(vim.uv.fs_unlink, data_dir .. '/' .. name)
      end
    end
  end
  fire(upgrade, { env = env, text = true, timeout = TIMEOUT_MS }, function(r)
    if r.code ~= 0 then
      -- WARN to the log file, never vim.notify: offline days are common
      -- and the screen must stay silent.
      vim.lsp.log.warn('simdref auto-update failed: ' .. (r.stderr or ''))
    end
    -- The refresh always runs, also when the upgrade failed: an offline
    -- upgrade must not block repairing a catalog.
    fire({ isa, 'vaddps', '--short' }, { env = env, text = true, timeout = TIMEOUT_MS }, function(r2)
      if r2.code ~= 0 then
        vim.lsp.log.warn('simdref catalog refresh failed: ' .. (r2.stderr or ''))
      end
    end)
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
