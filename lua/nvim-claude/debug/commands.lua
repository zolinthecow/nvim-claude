-- Debug-related user commands

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register(claude)
  local utils = require('nvim-claude.utils')
  local logger = require('nvim-claude.logger')
  local agent_provider = require('nvim-claude.agent_provider')

  -- ClaudeDebug: pane inspection
  define('ClaudeDebug', function()
    local cmd = "tmux list-panes -F '#{pane_id}:#{pane_pid}:#{pane_title}:#{pane_current_command}'"
    local result = utils.exec(cmd)
    local lines = { 'Agent Provider Debug Info:', '' }
    local provider_name = agent_provider.name() or 'unknown'
    table.insert(lines, 'Provider: ' .. provider_name)
    -- Attempt to print provider config details if available
    local details = {}
    if provider_name == 'claude' then
      local ok, cfg = pcall(require, 'nvim-claude.agent_provider.providers.claude.config')
      if ok and cfg then
        table.insert(details, 'spawn_command=' .. tostring(cfg.spawn_command))
        table.insert(details, 'background_spawn=' .. tostring(cfg.background_spawn))
        table.insert(details, 'pane_title=' .. tostring(cfg.pane_title))
      end
    elseif provider_name == 'opencode' then
      local ok, cfg = pcall(require, 'nvim-claude.agent_provider.providers.opencode.config')
      if ok and cfg then
        table.insert(details, 'spawn_command=' .. tostring(cfg.spawn_command))
        table.insert(details, 'background_spawn=' .. tostring(cfg.background_spawn))
        table.insert(details, 'pane_title=' .. tostring(cfg.pane_title))
      end
    end
    if #details > 0 then table.insert(lines, 'Config: ' .. table.concat(details, ', ')) end
    table.insert(lines, '')
    if result and result ~= '' then
      table.insert(lines, 'All panes:')
      for line in result:gmatch('[^\n]+') do
        local pane_id, pane_pid, pane_title, pane_cmd = line:match('^([^:]+):([^:]+):([^:]*):(.*)$')
        if pane_id and pane_pid then
          table.insert(lines, string.format('  %s: pid=%s, title="%s", cmd="%s"', pane_id, pane_pid, pane_title or '', pane_cmd or ''))
        end
      end
    else
      table.insert(lines, 'No panes found')
    end
    table.insert(lines, '')
    local pane = agent_provider.chat.ensure_pane()
    if pane then
      table.insert(lines, 'Detected provider chat pane: ' .. pane)
    else
      table.insert(lines, 'No provider chat pane detected')
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    local width, height = 80, math.min(#lines + 2, 25)
    local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height, col = (vim.o.columns - width) / 2, row = (vim.o.lines - height) / 2, style = 'minimal', border = 'rounded' })
    vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Normal,FloatBorder:Comment')
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, silent = true })
    vim.keymap.set('n', '<Esc>', '<cmd>close<CR>', { buffer = buf, silent = true })
  end, { desc = 'Debug chat pane detection' })

  -- Debug agents (summary)
  define('ClaudeDebugAgents', function()
    local ba = require('nvim-claude.background_agent')
    local project_root = utils.get_project_root()
    local current_dir = vim.fn.getcwd()
    local agents = ba.registry_agents()
    vim.notify('=== Claude Agents Debug ===', vim.log.levels.INFO)
    vim.notify('Current directory: ' .. current_dir, vim.log.levels.INFO)
    vim.notify('Project root: ' .. project_root, vim.log.levels.INFO)
    vim.notify('Agents for current project: ' .. #agents, vim.log.levels.INFO)
    for _, agent in ipairs(agents) do
      vim.notify(ba.registry_format(agent), vim.log.levels.INFO)
    end
  end, { desc = 'Debug Claude agents' })

  -- Debug registry summary
  define('ClaudeDebugRegistry', function()
    local ba = require('nvim-claude.background_agent')
    local project_root = utils.get_project_root()
    local current_dir = vim.fn.getcwd()
    local agents = ba.registry_agents()
    vim.notify('=== Claude Registry Debug ===', vim.log.levels.INFO)
    vim.notify('Current directory: ' .. current_dir, vim.log.levels.INFO)
    vim.notify('Project root: ' .. project_root, vim.log.levels.INFO)
    vim.notify('Agents for current project: ' .. #agents, vim.log.levels.INFO)
    for _, agent in ipairs(agents) do
      vim.notify(string.format('  %s', ba.registry_format(agent)), vim.log.levels.INFO)
    end
  end, { desc = 'Debug registry state' })

  -- Logs
  define('ClaudeDebugLogs', function()
    local project_root = utils.get_project_root()
    if not project_root then vim.notify('Not in a project directory', vim.log.levels.WARN); return end
    local debug_log = logger.get_log_file()
    vim.notify('=== Debug Log ===', vim.log.levels.INFO)
    vim.notify('Project: ' .. project_root, vim.log.levels.INFO)
    vim.notify('Log file: ' .. debug_log, vim.log.levels.INFO)
    local debug_size = vim.fn.getfsize(debug_log)
    if debug_size > 0 then
      vim.notify(string.format('Size: %.2f KB', debug_size / 1024), vim.log.levels.INFO)
    else
      vim.notify('Log: empty or not found', vim.log.levels.INFO)
    end
    local response = vim.fn.input('Open log? (y/n): ')
    if response:lower() == 'y' and debug_size > 0 then
      vim.cmd('edit ' .. debug_log)
      vim.cmd('normal! G')
    end
  end, { desc = 'Show debug log file location for current project' })

  define('ClaudeViewLog', function()
    local log_file = logger.get_log_file()
    if vim.fn.filereadable(log_file) == 1 then vim.cmd('edit ' .. log_file); vim.cmd('normal! G')
    else vim.notify('No log file found at: ' .. log_file, vim.log.levels.INFO) end
  end, { desc = 'View nvim-claude debug log' })

  define('ClaudeClearLog', function() logger.clear(); vim.notify('Debug log cleared', vim.log.levels.INFO) end, { desc = 'Clear nvim-claude debug log' })
end

return M
