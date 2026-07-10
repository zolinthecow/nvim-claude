-- Codex provider: OpenTelemetry + MCP installer for ~/.codex/config.toml

local M = {}

local utils = require 'nvim-claude.utils'
local cfg = require 'nvim-claude.agent_provider.providers.codex.config'

local marker_begin = '# BEGIN nvim-claude managed Codex configuration'
local marker_end = '# END nvim-claude managed Codex configuration'
local legacy_marker = '# Managed by nvim-claude (Codex provider)'

local function codex_home()
  return vim.env.CODEX_HOME or (vim.fn.expand('~') .. '/.codex')
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
  if vim.fn.isdirectory(home) == 1 then return true end
  return vim.fn.mkdir(home, 'p') == 1
end

local function toml_string(value)
  value = tostring(value)
    :gsub('\\', '\\\\')
    :gsub('"', '\\"')
    :gsub('\n', '\\n')
    :gsub('\r', '\\r')
    :gsub('\t', '\\t')
  return '"' .. value .. '"'
end

local function managed_block()
  local endpoint = string.format('http://127.0.0.1:%d/v1/logs', cfg.otel_port or 4318)
  local python = vim.fn.stdpath('data') .. '/nvim-claude/mcp-env/bin/python'
  local server_script = plugin_root() .. 'mcp-server/nvim-lsp-server.py'
  return table.concat({
    marker_begin,
    '[otel]',
    'environment = ' .. toml_string(cfg.otel_environment or 'dev'),
    'log_user_prompt = ' .. (cfg.otel_log_user_prompt and 'true' or 'false'),
    'exporter = { otlp-http = { endpoint = ' .. toml_string(endpoint) .. ', protocol = "json", headers = {} } }',
    '',
    '[mcp_servers.nvim-lsp]',
    'command = ' .. toml_string(python),
    'args = [' .. toml_string(server_script) .. ']',
    marker_end,
  }, '\n')
end

local function split_lines(content)
  local lines = {}
  if content == '' then return lines end
  for line in (content .. '\n'):gmatch('(.-)\n') do
    table.insert(lines, (line:gsub('\r$', '')))
  end
  return lines
end

local function header_text(line)
  return vim.trim((line:gsub('%s+#.*$', '')))
end

local function is_header(line)
  return header_text(line):match('^%[%[?.-%]%]?$') ~= nil
end

local function section_end(lines, start_index)
  for index = start_index + 1, #lines do
    if is_header(lines[index]) then return index - 1 end
  end
  return #lines
end

local function remove_range(lines, first, last)
  local result = {}
  for index, line in ipairs(lines) do
    if index < first or index > last then table.insert(result, line) end
  end
  return result
end

local function marker_range(lines)
  local starts = {}
  local finishes = {}
  for index, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed == marker_begin then table.insert(starts, index) end
    if trimmed == marker_end then table.insert(finishes, index) end
  end

  if #starts == 0 and #finishes == 0 then return nil end
  if #starts ~= 1 or #finishes ~= 1 or starts[1] >= finishes[1] then
    return false, 'Malformed nvim-claude markers in Codex config'
  end
  return { first = starts[1], last = finishes[1] }
end

local function remove_managed_marker(lines)
  local range, err = marker_range(lines)
  if range == false then return nil, err end
  if not range then return lines, false end
  return remove_range(lines, range.first, range.last), true
end

local function remove_legacy_sections(lines)
  local changed = false
  local index = 1
  while index <= #lines do
    if vim.trim(lines[index]) == legacy_marker
      and lines[index + 1]
      and header_text(lines[index + 1]) == '[otel]'
    then
      lines = remove_range(lines, index, section_end(lines, index + 1))
      changed = true
    elseif header_text(lines[index]) == '[mcp_servers.nvim-lsp]' then
      local last = section_end(lines, index)
      local section = table.concat(vim.list_slice(lines, index, last), '\n')
      if section:match('nvim%-claude') and section:match('nvim%-lsp%-server%.py') then
        lines = remove_range(lines, index, last)
        changed = true
      else
        index = last + 1
      end
    else
      index = index + 1
    end
  end
  return lines, changed
end

local function has_target_section(lines)
  for _, line in ipairs(lines) do
    if header_text(line) == '[otel]' then return true, '[otel]' end
    if header_text(line) == '[mcp_servers.nvim-lsp]' then
      return true, '[mcp_servers.nvim-lsp]'
    end
  end
  return false
end

local function validate_toml(content)
  if content == '' then return true end
  local managed_python = vim.fn.stdpath('data') .. '/nvim-claude/mcp-env/bin/python'
  local python = vim.fn.executable(managed_python) == 1 and managed_python or vim.fn.exepath('python3')
  if python == '' then return false, 'python3 is required to validate Codex config safely' end
  local output = vim.fn.system({
    python,
    '-c',
    table.concat({
      'import sys',
      'try:',
      '    import tomllib',
      'except ModuleNotFoundError:',
      '    import tomli as tomllib',
      'try:',
      '    tomllib.loads(sys.stdin.read())',
      'except Exception as error:',
      '    print(error, file=sys.stderr)',
      '    raise SystemExit(1)',
    }, '\n'),
  }, content)
  if vim.v.shell_error ~= 0 then
    output = vim.trim(output or '')
    return false, output ~= '' and output or 'Invalid TOML'
  end
  return true
end

local function read_config()
  local path = config_path()
  local content = utils.read_file(path)
  if content == nil and utils.file_exists(path) then
    return nil, 'Failed to read ' .. path
  end
  return content or ''
end

local function write_config_atomic(content)
  if not ensure_home() then return false, 'Failed to create ' .. codex_home() end
  local path = config_path()
  local temp_path = string.format('%s.nvim-claude.%d.%d', path, vim.fn.getpid(), vim.loop.hrtime())
  if not utils.write_file(temp_path, content) then
    return false, 'Failed to write temporary Codex config'
  end

  local stat = vim.loop.fs_stat(path)
  local mode = stat and stat.mode and (stat.mode % 512) or 384
  pcall(vim.loop.fs_chmod, temp_path, mode)
  local ok, err = vim.loop.fs_rename(temp_path, path)
  if not ok then
    pcall(vim.fn.delete, temp_path)
    return false, err or 'Failed to replace Codex config'
  end
  return true
end

local function config_with_managed_block(content)
  local valid, validation_err = validate_toml(content)
  if not valid then return nil, 'Existing Codex config is invalid: ' .. validation_err end

  local lines, marker_err = remove_managed_marker(split_lines(content))
  if not lines then return nil, marker_err end
  lines = remove_legacy_sections(lines)
  local conflict, section = has_target_section(lines)
  if conflict then
    return nil, section .. ' is user-managed; refusing to overwrite it'
  end

  local base = table.concat(lines, '\n'):gsub('%s+$', '')
  local result = (base ~= '' and (base .. '\n\n') or '') .. managed_block() .. '\n'
  valid, validation_err = validate_toml(result)
  if not valid then return nil, 'Generated Codex config is invalid: ' .. validation_err end
  return result
end

function M.install()
  local content, read_err = read_config()
  if content == nil then
    vim.notify('nvim-claude: ' .. read_err, vim.log.levels.ERROR)
    return false
  end

  local updated, update_err = config_with_managed_block(content)
  if not updated then
    vim.notify('nvim-claude: ' .. update_err, vim.log.levels.ERROR)
    return false
  end

  local ok, write_err = write_config_atomic(updated)
  if not ok then
    vim.notify('nvim-claude: ' .. write_err, vim.log.levels.ERROR)
    return false
  end
  vim.notify('nvim-claude: Codex telemetry + MCP server installed in ~/.codex/config.toml', vim.log.levels.INFO)
  return true
end

function M.uninstall()
  local content, read_err = read_config()
  if content == nil then
    vim.notify('nvim-claude: ' .. read_err, vim.log.levels.ERROR)
    return false
  end
  if content == '' then return true end

  local valid, validation_err = validate_toml(content)
  if not valid then
    vim.notify('nvim-claude: Existing Codex config is invalid: ' .. validation_err, vim.log.levels.ERROR)
    return false
  end

  local lines, marker_err = remove_managed_marker(split_lines(content))
  if not lines then
    vim.notify('nvim-claude: ' .. marker_err, vim.log.levels.ERROR)
    return false
  end
  local marker_changed = #lines ~= #split_lines(content)
  local legacy_changed
  lines, legacy_changed = remove_legacy_sections(lines)
  if not marker_changed and not legacy_changed then return true end

  local updated = table.concat(lines, '\n'):gsub('%s+$', '')
  if updated ~= '' then updated = updated .. '\n' end
  valid, validation_err = validate_toml(updated)
  if not valid then
    vim.notify('nvim-claude: Refusing to write invalid Codex config: ' .. validation_err, vim.log.levels.ERROR)
    return false
  end

  local ok, write_err = write_config_atomic(updated)
  if not ok then
    vim.notify('nvim-claude: ' .. write_err, vim.log.levels.ERROR)
    return false
  end
  vim.notify('nvim-claude: Codex telemetry + MCP config removed from ~/.codex/config.toml', vim.log.levels.INFO)
  return true
end

return M
