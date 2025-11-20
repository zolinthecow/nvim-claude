-- Codex provider: OpenTelemetry + MCP installer for ~/.codex/config.toml

local M = {}

local utils = require 'nvim-claude.utils'
local cfg = require('nvim-claude.agent_provider.providers.codex.config')

local function codex_home()
  local home = vim.env.CODEX_HOME or (vim.fn.expand('~') .. '/.codex')
  return home
end

local function config_path()
  return codex_home() .. '/config.toml'
end

local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  local root = src:match('(.*/)lua/nvim%-claude/')
  if root then return root end
  return vim.fn.fnamemodify(src, ':h:h:h:h') .. '/'
end

local function ensure_home()
  local home = codex_home()
  if vim.fn.isdirectory(home) == 0 then
    vim.fn.mkdir(home, 'p')
  end
  return home
end

local function otel_block()
  local endpoint = string.format('http://127.0.0.1:%d/v1/logs', cfg.otel_port or 4318)
  local t = {}
  table.insert(t, '# Managed by nvim-claude (Codex provider)')
  table.insert(t, '[otel]')
  table.insert(t, string.format('environment = %q', cfg.otel_environment or 'dev'))
  table.insert(t, string.format('log_user_prompt = %s', cfg.otel_log_user_prompt and 'true' or 'false'))
  table.insert(t,
    string.format('exporter = { otlp-http = { endpoint = %q, protocol = "json", headers = {} } }', endpoint))
  table.insert(t, '')
  return table.concat(t, '\n')
end

local function read_config_lines()
  local path = config_path()
  local content = utils.read_file(path) or ''
  local lines = {}
  for l in (content .. '\n'):gmatch('([^\n]*)\n') do table.insert(lines, l) end
  return lines
end

local function remove_hooks_sections(lines)
  local result = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match('^%s*%[%[?hooks') then
      i = i + 1
      while i <= #lines do
        local peek = lines[i]
        if peek:match('^%s*%[%[?hooks') then
          i = i + 1
        elseif peek:match('^%s*%[.+%]%s*$') then
          break
        else
          i = i + 1
        end
      end
    else
      table.insert(result, line)
      i = i + 1
    end
  end
  return result
end

local function strip_otel_blocks(lines)
  local result = {}
  local skip = false
  for _, line in ipairs(lines) do
    if skip then
      if line:match('^%s*%[.+%]%s*$') then
        skip = false
        table.insert(result, line)
      end
    else
      if line:match('^%s*# Managed by nvim%-claude %(Codex provider%)%s*$') then
        skip = true
      elseif line:match('^%s*%[otel%]%s*$') then
        skip = true
      else
        table.insert(result, line)
      end
    end
  end
  if skip then
    -- block ran to EOF; drop trailing comment/newlines
  end
  return result
end

local function write_otel_config()
  ensure_home()
  local lines = read_config_lines()
  lines = remove_hooks_sections(lines)
  lines = strip_otel_blocks(lines)

  local content = table.concat(lines, '\n')
  content = content:gsub('%s+$', '')
  if content ~= '' then content = content .. '\n\n' end
  local new_content = content .. otel_block()
  return utils.write_file(config_path(), new_content)
end

-- Write or update MCP server entry for Codex to use our LSP server
local function write_mcp_server()
  ensure_home()
  local path = config_path()
  local content = utils.read_file(path) or ''
  local lines = {}
  for l in (content .. '\n'):gmatch('([^\n]*)\n') do table.insert(lines, l) end

  -- Compute paths
  local python = (vim.fn.stdpath('data') .. '/nvim-claude/mcp-env/bin/python')
  local root = plugin_root()
  local server_script = root .. 'mcp-server/nvim-lsp-server.py'

  -- Build block
  local block = {
    '[mcp_servers.nvim-lsp]',
    string.format('command = %q', python),
    string.format('args = [%q]', server_script),
  }
  local new_block = table.concat(block, '\n')

  -- Locate existing [mcp_servers.nvim-lsp] block
  local start_idx, end_idx = nil, nil
  for i, l in ipairs(lines) do
    if l:match('^%s*%[mcp_servers%.nvim%-lsp%]%s*$') then start_idx = i break end
  end
  if start_idx then
    end_idx = #lines + 1
    for j = start_idx + 1, #lines do
      if lines[j]:match('^%s*%[.+%]%s*$') then end_idx = j; break end
    end
  end

  local new_content
  if start_idx then
    local before = table.concat(vim.list_slice(lines, 1, start_idx - 1), '\n')
    local after = table.concat(vim.list_slice(lines, end_idx, #lines), '\n')
    new_content = ''
    if before ~= '' then new_content = before .. '\n' end
    new_content = new_content .. new_block .. '\n'
    if after ~= '' then new_content = new_content .. after .. '\n' end
  else
    new_content = content
    if new_content ~= '' and not new_content:match('\n$') then new_content = new_content .. '\n' end
    new_content = new_content .. new_block .. '\n'
  end
  return utils.write_file(path, new_content)
end

function M.install()
  local ok = write_otel_config()
  if not ok then
    vim.notify('nvim-claude: Failed to configure Codex OpenTelemetry exporter', vim.log.levels.ERROR)
    return false
  end

  -- Write MCP server entry
  local ok_mcp = write_mcp_server()
  if ok_mcp then
    vim.notify('nvim-claude: Codex telemetry + MCP server installed in ~/.codex/config.toml', vim.log.levels.INFO)
  else
    vim.notify('nvim-claude: Codex telemetry enabled; failed to write MCP server entry', vim.log.levels.WARN)
  end
  return true
end

function M.uninstall()
  -- Best-effort: remove [otel] block entirely
  local path = config_path()
  local content = utils.read_file(path)
  if not content or content == '' then return true end
  local lines = {}
  for l in (content .. '\n'):gmatch('([^\n]*)\n') do table.insert(lines, l) end
  local start_idx, end_idx = nil, nil
  for i, l in ipairs(lines) do if l:match('^%s*%[otel%]%s*$') then start_idx = i break end end
  if start_idx then
    end_idx = #lines + 1
    for j = start_idx + 1, #lines do if lines[j]:match('^%s*%[.+%]%s*$') then end_idx = j; break end end
    local before = table.concat(vim.list_slice(lines, 1, start_idx - 1), '\n')
    local after = table.concat(vim.list_slice(lines, end_idx, #lines), '\n')
    local new_content = ''
    if before ~= '' then new_content = before .. '\n' end
    if after ~= '' then new_content = new_content .. after .. '\n' end
    local ok = utils.write_file(path, new_content)
    if not ok then
      vim.notify('nvim-claude: Failed to update ~/.codex/config.toml', vim.log.levels.WARN)
      return false
    end
  end
  vim.notify('nvim-claude: Codex OpenTelemetry config removed from ~/.codex/config.toml', vim.log.levels.INFO)
  return true
end

return M
