-- Codex provider: hooks installer for ~/.codex/config.toml

local M = {}

local utils = require 'nvim-claude.utils'
local logger = require 'nvim-claude.logger'

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

local function hooks_block(paths)
  local t = {}
  table.insert(t, '[hooks]')
  -- Use per-rule hooks exclusively to avoid ambiguity; keep prompt/stop at top level
  table.insert(t, string.format('user_prompt_submit = ["%s"]', paths.user_prompt))
  table.insert(t, string.format('stop = ["%s"]', paths.stop))
  table.insert(t, 'timeout_ms = 10000')
  table.insert(t, '')
  -- Shell-only rules: we parse apply_patch/write/delete in the shell hooks
  table.insert(t, '[[hooks.pre_tool_use_rules]]')
  table.insert(t, string.format('argv = ["%s"]', paths.shell_pre))
  table.insert(t, 'include = ["shell"]')
  table.insert(t, 'exclude = []')
  table.insert(t, '')
  table.insert(t, '[[hooks.post_tool_use_rules]]')
  table.insert(t, string.format('argv = ["%s"]', paths.shell_post))
  table.insert(t, 'include = ["shell"]')
  table.insert(t, 'exclude = []')
  table.insert(t, '')
  return table.concat(t, '\n')
end

local function write_config_with_hooks(paths)
  ensure_home()
  local path = config_path()
  local content = utils.read_file(path) or ''
  local lines = {}
  for l in (content .. '\n'):gmatch('([^\n]*)\n') do table.insert(lines, l) end

  -- Locate existing hooks-related blocks: [hooks], [hooks.*], [[hooks.*]]
  local start_idx, end_idx = nil, nil
  local in_hooks = false
  for i, l in ipairs(lines) do
    local is_header = l:match('^%s*%[') ~= nil
    local is_hooks_header = l:match('^%s*%[%[?hooks') ~= nil
    if is_header and is_hooks_header then
      if not in_hooks then
        start_idx = i
        in_hooks = true
      end
    elseif is_header and in_hooks and (not is_hooks_header) then
      end_idx = i
      break
    end
  end
  if in_hooks and not end_idx then end_idx = #lines + 1 end

  local new_block = hooks_block(paths)
  local new_content
  if start_idx then
    local before = table.concat(vim.list_slice(lines, 1, start_idx - 1), '\n')
    local after = table.concat(vim.list_slice(lines, end_idx, #lines), '\n')
    new_content = ''
    if before ~= '' then new_content = before .. '\n' end
    new_content = new_content .. new_block
    if after ~= '' then new_content = new_content .. after .. '\n' end
  else
    new_content = content
    if new_content ~= '' and not new_content:match('\n$') then new_content = new_content .. '\n' end
    new_content = new_content .. new_block
  end
  return utils.write_file(path, new_content)
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
  local root = plugin_root()
  local base = 'lua/nvim-claude/agent_provider/providers/codex/codex-hooks/'
  local pre = root .. base .. 'pre-tool-use.sh'
  local post = root .. base .. 'post-tool-use.sh'
  local user_prompt = root .. base .. 'user-prompt-submit.sh'
  local stop = root .. base .. 'stop-hook-validator.sh'
  local shell_pre = root .. base .. 'shell-pre.sh'
  local shell_post = root .. base .. 'shell-post.sh'

  -- ensure executables
  for _, p in ipairs({ pre, post, user_prompt, stop, shell_pre, shell_post, root .. base .. 'hook-common.sh' }) do
    if vim.fn.filereadable(p) == 1 then
      pcall(function() utils.exec(string.format('chmod +x %s 2>/dev/null', vim.fn.shellescape(p))) end)
    end
  end

  local ok = write_config_with_hooks({ pre = pre, post = post, user_prompt = user_prompt, stop = stop, shell_pre = shell_pre, shell_post = shell_post })
  if not ok then
    vim.notify('nvim-claude: Failed to install Codex hooks', vim.log.levels.ERROR)
    return false
  end
  -- Write MCP server entry
  local ok_mcp = write_mcp_server()
  if ok_mcp then
    vim.notify('nvim-claude: Codex hooks + MCP server installed in ~/.codex/config.toml', vim.log.levels.INFO)
  else
    vim.notify('nvim-claude: Codex hooks installed; failed to write MCP server entry', vim.log.levels.WARN)
  end
  return true
end

function M.uninstall()
  -- Best-effort: remove [hooks] block entirely
  local path = config_path()
  local content = utils.read_file(path)
  if not content or content == '' then return true end
  local lines = {}
  for l in (content .. '\n'):gmatch('([^\n]*)\n') do table.insert(lines, l) end
  local start_idx, end_idx = nil, nil
  for i, l in ipairs(lines) do if l:match('^%s*%[hooks%]%s*$') then start_idx = i break end end
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
  vim.notify('nvim-claude: Codex hooks uninstalled from ~/.codex/config.toml', vim.log.levels.INFO)
  return true
end

return M
