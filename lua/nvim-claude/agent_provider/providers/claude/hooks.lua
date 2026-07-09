-- Claude provider: hook installer (writes .claude/settings.local.json)

local M = {}

local utils = require 'nvim-claude.utils'
local uv = vim.uv or vim.loop

local hook_sections = {
  'PreToolUse',
  'PostToolUse',
  'Stop',
  'UserPromptSubmit',
}

local legacy_script_names = {
  'pre-hook-wrapper.sh',
  'post-hook-wrapper.sh',
  'bash-hook-wrapper.sh',
  'bash-post-hook-wrapper.sh',
  'stop-hook-validator.sh',
  'user-prompt-hook-wrapper.sh',
}

local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  local root = src:match('(.*/)lua/nvim%-claude/')
  if root then return root end
  return vim.fn.fnamemodify(src, ':h:h:h:h') .. '/'
end

local function is_list(value)
  if vim.islist then return vim.islist(value) end
  return vim.tbl_islist(value)
end

local function validate_hook_section(name, section)
  if type(section) ~= 'table' or not is_list(section) then
    return false, string.format('Claude hook section %s must be a list', name)
  end

  for index, entry in ipairs(section) do
    if type(entry) ~= 'table' then
      return false, string.format('Claude hook entry %s[%d] must be an object', name, index)
    end
    if entry.hooks ~= nil then
      if type(entry.hooks) ~= 'table' or not is_list(entry.hooks) then
        return false, string.format('Claude hook entry %s[%d].hooks must be a list', name, index)
      end
      for hook_index, hook in ipairs(entry.hooks) do
        if type(hook) ~= 'table' then
          return false, string.format('Claude hook %s[%d].hooks[%d] must be an object', name, index, hook_index)
        end
      end
    end
  end

  return true
end

local function load_settings()
  local project_root = utils.get_project_root()
  if not project_root then return nil, 'Not in a git repository' end
  local claude_dir = project_root .. '/.claude'
  local settings_file = claude_dir .. '/settings.local.json'
  local settings = {}
  if utils.file_exists(settings_file) then
    local read_err
    settings, read_err = utils.read_json(settings_file)
    if settings == nil then return nil, read_err or 'Failed to read Claude settings' end
    if type(settings) ~= 'table' or is_list(settings) then
      return nil, 'Claude settings must contain a JSON object'
    end
  end

  if settings.hooks ~= nil and (type(settings.hooks) ~= 'table' or is_list(settings.hooks)) then
    return nil, 'Claude settings hooks must contain a JSON object'
  end
  if settings.hooks then
    for _, name in ipairs(hook_sections) do
      if settings.hooks[name] ~= nil then
        local ok, err = validate_hook_section(name, settings.hooks[name])
        if not ok then return nil, err end
      end
    end
  end

  return settings, settings_file, claude_dir
end

local function ensure_hook_sections(settings)
  settings.hooks = settings.hooks or vim.empty_dict()
  for _, name in ipairs(hook_sections) do
    settings.hooks[name] = settings.hooks[name] or {}
  end
end

local function write_settings(path, settings)
  local encoded, content = pcall(vim.fn.json_encode, settings)
  if not encoded then return false, 'Failed to encode JSON: ' .. tostring(content) end

  local temp_path = string.format('%s.nvim-claude.%d.%d', path, vim.fn.getpid(), uv.hrtime())
  if not utils.write_file(temp_path, content .. '\n') then
    return false, 'Failed to write temporary Claude settings'
  end

  local stat = uv.fs_stat(path)
  local mode = stat and stat.mode and (stat.mode % 512) or 384
  pcall(uv.fs_chmod, temp_path, mode)
  local ok, err = uv.fs_rename(temp_path, path)
  if not ok then
    pcall(vim.fn.delete, temp_path)
    return false, err or 'Failed to replace Claude settings'
  end
  return true
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

local function legacy_commands(root)
  local commands = {}
  for _, script_name in ipairs(legacy_script_names) do
    commands[root .. 'scripts/' .. script_name] = true
  end
  return commands
end

local function has_only_hook_container_keys(entry)
  for key in pairs(entry) do
    if key ~= 'matcher' and key ~= 'hooks' then return false end
  end
  return true
end

local function prune_legacy(list, commands)
  local function keep_entry(e)
    if not e.hooks then return true end
    local new_hooks = {}
    local removed = false
    for _, h in ipairs(e.hooks) do
      if commands[h.command] then removed = true
      else table.insert(new_hooks, h) end
    end
    e.hooks = new_hooks
    return #e.hooks > 0 or not removed or not has_only_hook_container_keys(e)
  end
  local out = {}
  for _, e in ipairs(list or {}) do
    if keep_entry(e) then table.insert(out, e) end
  end
  return out
end

function M.install()
  local settings, path_or_err, claude_dir = load_settings()
  if not settings then
    vim.notify('nvim-claude: ' .. (path_or_err or 'Failed to prepare settings'), vim.log.levels.ERROR)
    return false
  end
  if vim.fn.isdirectory(claude_dir) == 0 and vim.fn.mkdir(claude_dir, 'p') ~= 1 then
    vim.notify('nvim-claude: Failed to create .claude directory', vim.log.levels.ERROR)
    return false
  end
  local settings_file = path_or_err
  ensure_hook_sections(settings)
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

  local legacy = legacy_commands(root)
  settings.hooks.PreToolUse = prune_legacy(settings.hooks.PreToolUse, legacy)
  settings.hooks.PostToolUse = prune_legacy(settings.hooks.PostToolUse, legacy)
  settings.hooks.Stop = prune_legacy(settings.hooks.Stop, legacy)
  settings.hooks.UserPromptSubmit = prune_legacy(settings.hooks.UserPromptSubmit, legacy)

  add_command_to_section(settings.hooks.PreToolUse, pre, 'Edit|Write|MultiEdit')
  add_command_to_section(settings.hooks.PostToolUse, post, 'Edit|Write|MultiEdit')
  add_command_to_section(settings.hooks.PreToolUse, bash_pre, 'Bash')
  add_command_to_section(settings.hooks.PostToolUse, bash_post, 'Bash')
  add_command_to_section(settings.hooks.Stop, stop, nil)
  add_command_to_section(settings.hooks.UserPromptSubmit, user_prompt, nil)

  local ok, err = write_settings(settings_file, settings)
  if not ok then
    vim.notify('nvim-claude: Failed to write settings: ' .. (err or 'unknown'), vim.log.levels.ERROR)
    return false
  end

  vim.notify('nvim-claude: Claude Code hooks installed', vim.log.levels.INFO)
  return true
end

local function remove_command_from_section(list, command, matcher)
  local changed = false
  local function prune_hooks(e)
    if not e.hooks then return false end
    local managed_container = #e.hooks == 1
      and e.hooks[1].command == command
      and has_only_hook_container_keys(e)
    local new = {}
    for _, h in ipairs(e.hooks) do
      if h.command == command then changed = true
      else table.insert(new, h) end
    end
    e.hooks = new
    return managed_container
  end

  local new_list = {}
  for _, e in ipairs(list or {}) do
    if matcher then
      if e.matcher == matcher then
        local managed_container = prune_hooks(e)
        if not managed_container then table.insert(new_list, e) end
      else
        table.insert(new_list, e)
      end
    else
      local managed_container = prune_hooks(e)
      if not managed_container then table.insert(new_list, e) end
    end
  end
  return new_list, changed
end

function M.uninstall()
  local settings, path_or_err = load_settings()
  if not settings then
    vim.notify('nvim-claude: ' .. (path_or_err or 'Failed to prepare settings'), vim.log.levels.ERROR)
    return false
  end
  local settings_file = path_or_err
  if not utils.file_exists(settings_file) then return true end
  if not settings.hooks then return true end
  local root = plugin_root()
  local base = 'lua/nvim-claude/agent_provider/providers/claude/claude-hooks/'
  local pre = root .. base .. 'pre-hook-wrapper.sh'
  local post = root .. base .. 'post-hook-wrapper.sh'
  local bash_pre = root .. base .. 'bash-hook-wrapper.sh'
  local bash_post = root .. base .. 'bash-post-hook-wrapper.sh'
  local stop = root .. base .. 'stop-hook-validator.sh'
  local user_prompt = root .. base .. 'user-prompt-hook-wrapper.sh'

  local changed = false
  local function remove(section, command, matcher)
    if not settings.hooks[section] then return end
    local section_changed
    settings.hooks[section], section_changed = remove_command_from_section(settings.hooks[section], command, matcher)
    changed = changed or section_changed
  end

  remove('PreToolUse', pre, 'Edit|Write|MultiEdit')
  remove('PostToolUse', post, 'Edit|Write|MultiEdit')
  remove('PreToolUse', bash_pre, 'Bash')
  remove('PostToolUse', bash_post, 'Bash')
  remove('Stop', stop, nil)
  remove('UserPromptSubmit', user_prompt, nil)
  if not changed then return true end

  local ok, err = write_settings(settings_file, settings)
  if not ok then
    vim.notify('nvim-claude: Failed to write settings: ' .. (err or 'unknown'), vim.log.levels.ERROR)
    return false
  end
  vim.notify('nvim-claude: Claude Code hooks uninstalled', vim.log.levels.INFO)
  return true
end

return M
