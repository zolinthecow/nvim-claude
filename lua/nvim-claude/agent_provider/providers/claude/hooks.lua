-- Claude provider: hook installer (writes .claude/settings.local.json)

local M = {}

local utils = require 'nvim-claude.utils'

local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  local root = src:match('(.*/)lua/nvim%-claude/')
  if root then return root end
  return vim.fn.fnamemodify(src, ':h:h:h:h') .. '/'
end

local function ensure_settings()
  local project_root = utils.get_project_root()
  if not project_root then return nil, 'Not in a git repository' end
  local claude_dir = project_root .. '/.claude'
  if vim.fn.isdirectory(claude_dir) == 0 then
    local ok = vim.fn.mkdir(claude_dir, 'p')
    if ok ~= 1 then return nil, 'Failed to create .claude directory' end
  end
  local settings_file = claude_dir .. '/settings.local.json'
  local settings = {}
  if utils.file_exists(settings_file) then
    settings = utils.read_json(settings_file) or {}
  end
  settings.hooks = settings.hooks or {}
  settings.hooks.PreToolUse = settings.hooks.PreToolUse or {}
  settings.hooks.PostToolUse = settings.hooks.PostToolUse or {}
  settings.hooks.Stop = settings.hooks.Stop or {}
  return settings, settings_file
end

local function add_command_to_section(list, command, matcher)
  if matcher then
    local entry
    for _, e in ipairs(list) do
      if e.matcher == matcher then entry = e break end
    end
    if not entry then
      entry = { matcher = matcher, hooks = {} }
      table.insert(list, entry)
    end
    entry.hooks = entry.hooks or {}
    local exists = false
    for _, h in ipairs(entry.hooks) do
      if h.command == command then exists = true break end
    end
    if not exists then table.insert(entry.hooks, { type = 'command', command = command }) end
  else
    local exists = false
    for _, e in ipairs(list) do
      if e.hooks then
        for _, h in ipairs(e.hooks) do
          if h.command == command then exists = true break end
        end
      end
      if exists then break end
    end
    if not exists then
      table.insert(list, { hooks = { { type = 'command', command = command } } })
    end
  end
end

local function prune_legacy(list)
  local function keep_entry(e)
    if not e or not e.hooks then return false end
    local new_hooks = {}
    for _, h in ipairs(e.hooks) do
      if h.command and not h.command:match('/scripts/') then
        table.insert(new_hooks, h)
      end
    end
    e.hooks = new_hooks
    return #e.hooks > 0
  end
  local out = {}
  for _, e in ipairs(list or {}) do
    if e.matcher then
      if keep_entry(e) then table.insert(out, e) end
    else
      if keep_entry(e) then table.insert(out, e) end
    end
  end
  return out
end

function M.install()
  local settings, path_or_err = ensure_settings()
  if not settings then
    vim.notify('nvim-claude: ' .. (path_or_err or 'Failed to prepare settings'), vim.log.levels.ERROR)
    return false
  end
  local settings_file = path_or_err
  local root = plugin_root()
  local base = 'lua/nvim-claude/agent_provider/providers/claude/claude-hooks/'
  local pre = root .. base .. 'pre-hook-wrapper.sh'
  local post = root .. base .. 'post-hook-wrapper.sh'
  local bash_pre = root .. base .. 'bash-hook-wrapper.sh'
  local bash_post = root .. base .. 'bash-post-hook-wrapper.sh'
  local stop = root .. base .. 'stop-hook-validator.sh'
  local user_prompt = root .. base .. 'user-prompt-hook-wrapper.sh'

  -- Ensure hook scripts are executable
  local scripts = {
    pre, post, bash_pre, bash_post, stop,
    user_prompt,
    root .. base .. 'hook-common.sh',
    root .. 'rpc/nvim-rpc.sh',
  }
  for _, p in ipairs(scripts) do
    if vim.fn.filereadable(p) == 1 then
      pcall(function() utils.exec(string.format('chmod +x %s 2>/dev/null', vim.fn.shellescape(p))) end)
    end
  end

  -- Prune legacy script paths (moved from scripts/ to claude-hooks/)
  settings.hooks.PreToolUse = prune_legacy(settings.hooks.PreToolUse)
  settings.hooks.PostToolUse = prune_legacy(settings.hooks.PostToolUse)
  settings.hooks.Stop = prune_legacy(settings.hooks.Stop)
  settings.hooks.UserPromptSubmit = prune_legacy(settings.hooks.UserPromptSubmit)

  add_command_to_section(settings.hooks.PreToolUse, pre, 'Edit|Write|MultiEdit')
  add_command_to_section(settings.hooks.PostToolUse, post, 'Edit|Write|MultiEdit')
  add_command_to_section(settings.hooks.PreToolUse, bash_pre, 'Bash')
  add_command_to_section(settings.hooks.PostToolUse, bash_post, 'Bash')
  add_command_to_section(settings.hooks.Stop, stop, nil)
  add_command_to_section(settings.hooks.UserPromptSubmit, user_prompt, nil)

  -- Sanitize stale/invalid permissions from older versions
  do
    local perms = settings.permissions or {}
    local allow = perms.allow or {}
    local new_allow, seen_bash = {}, false
    local function valid_bash_pattern(item)
      if item == 'Bash' then return true end
      local inner = item:match('^Bash%((.*)%)$')
      if not inner then return false end
      inner = inner:gsub('^%s+', ''):gsub('%s+$', '')
      if inner == '' then return false end
      if inner:match('[\n\r]') or inner:match('"') then return false end
      if inner:match('nvr%-proxy') or inner:match('mcp%-bridge') or inner:match('nvim%-claude%.hooks') then return false end
      return true
    end
    for _, item in ipairs(allow) do
      if type(item) == 'string' then
        if item == 'Bash' then
          if not seen_bash then table.insert(new_allow, 'Bash'); seen_bash = true end
        elseif item:match('^Bash%(') and valid_bash_pattern(item) then
          table.insert(new_allow, item)
        end
      end
    end
    if not seen_bash then table.insert(new_allow, 'Bash') end
    if not settings.permissions then settings.permissions = {} end
    settings.permissions.allow = new_allow
  end

  local ok, err = utils.write_json(settings_file, settings)
  if not ok then
    vim.notify('nvim-claude: Failed to write settings: ' .. (err or 'unknown'), vim.log.levels.ERROR)
    return false
  end

  vim.notify('nvim-claude: Claude Code hooks installed', vim.log.levels.INFO)
  return true
end

local function remove_command_from_section(list, command, matcher)
  local function prune_hooks(e)
    if not e.hooks then return end
    local new = {}
    for _, h in ipairs(e.hooks) do
      if h.command ~= command then table.insert(new, h) end
    end
    e.hooks = new
  end

  local new_list = {}
  for _, e in ipairs(list or {}) do
    if matcher then
      if e.matcher == matcher then
        prune_hooks(e)
        if e.hooks and #e.hooks > 0 then table.insert(new_list, e) end
      else
        table.insert(new_list, e)
      end
    else
      prune_hooks(e)
      if not e.hooks or #e.hooks == 0 then
        -- drop
      else
        table.insert(new_list, e)
      end
    end
  end
  return new_list
end

function M.uninstall()
  local settings, path_or_err = ensure_settings()
  if not settings then
    vim.notify('nvim-claude: ' .. (path_or_err or 'Failed to prepare settings'), vim.log.levels.ERROR)
    return false
  end
  local settings_file = path_or_err
  local root = plugin_root()
  local base = 'lua/nvim-claude/agent_provider/providers/claude/claude-hooks/'
  local pre = root .. base .. 'pre-hook-wrapper.sh'
  local post = root .. base .. 'post-hook-wrapper.sh'
  local bash_pre = root .. base .. 'bash-hook-wrapper.sh'
  local bash_post = root .. base .. 'bash-post-hook-wrapper.sh'
  local stop = root .. base .. 'stop-hook-validator.sh'
  local user_prompt = root .. base .. 'user-prompt-hook-wrapper.sh'

  settings.hooks.PreToolUse = remove_command_from_section(settings.hooks.PreToolUse, pre, 'Edit|Write|MultiEdit')
  settings.hooks.PostToolUse = remove_command_from_section(settings.hooks.PostToolUse, post, 'Edit|Write|MultiEdit')
  settings.hooks.PreToolUse = remove_command_from_section(settings.hooks.PreToolUse, bash_pre, 'Bash')
  settings.hooks.PostToolUse = remove_command_from_section(settings.hooks.PostToolUse, bash_post, 'Bash')
  settings.hooks.Stop = remove_command_from_section(settings.hooks.Stop, stop, nil)
  settings.hooks.UserPromptSubmit = remove_command_from_section(settings.hooks.UserPromptSubmit, user_prompt, nil)

  local ok, err = utils.write_json(settings_file, settings)
  if not ok then
    vim.notify('nvim-claude: Failed to write settings: ' .. (err or 'unknown'), vim.log.levels.ERROR)
    return false
  end
  vim.notify('nvim-claude: Claude Code hooks uninstalled', vim.log.levels.INFO)
  return true
end

return M
