-- Codex OTEL relay manager (external Python daemon)

local M = {}

local uv = vim.loop
local utils = require 'nvim-claude.utils'
local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local logger = require 'nvim-claude.logger'

local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  local root = src:match('(.*/)lua/nvim%-claude/')
  if root then return root end
  return vim.fn.fnamemodify(src, ':h:h:h:h') .. '/'
end

local function mcp_python()
  local path = vim.fn.stdpath('data') .. '/nvim-claude/mcp-env/bin/python'
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  return nil
end

local function resolve_python()
  if cfg.relay_python and cfg.relay_python ~= '' then
    return cfg.relay_python
  end
  return mcp_python() or 'python3'
end

local function runtime_dir()
  return vim.env.XDG_RUNTIME_DIR or '/tmp'
end

local function pid_file()
  return runtime_dir() .. '/nvim-claude-codex-otel-relay.pid'
end

local function log_file()
  local dir = vim.fn.stdpath('data') .. '/nvim-claude/logs'
  utils.ensure_dir(dir)
  return dir .. '/codex-otel-relay.log'
end

local function script_path()
  return plugin_root() .. 'scripts/codex-otel-relay.py'
end

local function read_pid()
  local path = pid_file()
  if vim.fn.filereadable(path) == 1 then
    local p = tonumber(vim.fn.readfile(path)[1])
    return p
  end
  return nil
end

local function is_running(pid)
  if not pid then return false end
  local ok = pcall(function() return uv.kill(pid, 0) end)
  return ok == true
end

local function write_pid(pid)
  vim.fn.writefile({ tostring(pid) }, pid_file())
end

local function remove_pid()
  local path = pid_file()
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

local function spawn_daemon()
  local python = resolve_python()
  local cmd = {
    python,
    script_path(),
    '--port',
    tostring(cfg.otel_port),
    '--pid-file',
    pid_file(),
    '--log-file',
    log_file(),
  }
  local ok, jid = pcall(vim.fn.jobstart, cmd, { detach = true })
  if not ok then
    logger.error('codex_relay', 'Failed to start OTEL relay', { error = jid, python = python })
    return false
  end

  -- Wait briefly for pid file to appear to confirm startup
  local waited = 0
  local max_wait = 1500
  while waited < max_wait do
    local pid = read_pid()
    if pid and is_running(pid) then
      logger.info('codex_relay', 'Started OTEL relay daemon', { job_id = jid, pid = pid, port = cfg.otel_port, python = python })
      return true
    end
    vim.wait(100, function() return false end)
    waited = waited + 100
  end

  logger.error('codex_relay', 'OTEL relay failed to start (no pid file)', { job_id = jid, python = python, port = cfg.otel_port })
  return false
end

local function check_port(port)
  local ok, res = pcall(function()
    local tcp = uv.new_tcp()
    local done = false
    local success = false
    tcp:connect('127.0.0.1', port, function(err)
      success = err == nil
      if tcp then
        pcall(tcp.shutdown, tcp)
        pcall(tcp.close, tcp)
      end
      done = true
    end)
    vim.wait(200, function() return done end, 10)
    return success
  end)
  if ok then return res end
  return false
end

-- Public: ensure the daemon is running (idempotent)
function M.ensure_running()
  if not cfg.use_daemon then
    return true
  end

  local existing = read_pid()
  if is_running(existing) then
    return true
  end

  -- If something else already holds the port, avoid spinning up a daemon that will fail immediately
  if check_port(cfg.otel_port) then
    logger.warn('codex_relay', 'OTEL port already in use; not starting relay', { port = cfg.otel_port })
    return false
  end

  return spawn_daemon()
end

-- Public: stop the daemon if running
function M.stop()
  local pid = read_pid()
  if not pid then
    vim.notify('nvim-claude: Codex OTEL relay not running', vim.log.levels.INFO)
    return false
  end
  local ok = pcall(function()
    uv.kill(pid, vim.loop.constants.SIGTERM or 15)
  end)
  if ok then
    remove_pid()
    vim.notify('nvim-claude: Stopped Codex OTEL relay', vim.log.levels.INFO)
    return true
  else
    vim.notify('nvim-claude: Failed to stop Codex OTEL relay (maybe already dead)', vim.log.levels.WARN)
    remove_pid()
    return false
  end
end

-- Public: report status
function M.status()
  local pid = read_pid()
  if pid and is_running(pid) then
    return string.format('running (pid %d, port %d)', pid, cfg.otel_port)
  end
  return 'stopped'
end

-- Public: health details for user commands
function M.health()
  local pid = read_pid()
  local running = is_running(pid)
  local listening = check_port(cfg.otel_port)
  return {
    use_daemon = cfg.use_daemon,
    pid = pid,
    running = running,
    listening = listening,
    port = cfg.otel_port,
    pid_file = pid_file(),
    log_file = log_file(),
    python = resolve_python(),
  }
end

return M
