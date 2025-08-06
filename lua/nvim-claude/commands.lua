-- Commands module for nvim-claude
local M = {}

-- Reference to main module
local claude = nil

-- Setup commands
function M.setup(claude_module)
  claude = claude_module

  -- ClaudeChat command
  vim.api.nvim_create_user_command('ClaudeChat', function()
    M.claude_chat()
  end, {
    desc = 'Open Claude in a tmux pane',
  })

  -- ClaudeSendBuffer command
  vim.api.nvim_create_user_command('ClaudeSendBuffer', function()
    M.send_buffer()
  end, {
    desc = 'Send current buffer to Claude',
  })

  -- ClaudeSendSelection command (visual mode)
  vim.api.nvim_create_user_command('ClaudeSendSelection', function(opts)
    M.send_selection(opts.line1, opts.line2)
  end, {
    desc = 'Send selected text to Claude',
    range = true,
  })

  -- ClaudeSendHunk command
  vim.api.nvim_create_user_command('ClaudeSendHunk', function()
    M.send_hunk()
  end, {
    desc = 'Send git hunk under cursor to Claude',
  })

  -- ClaudeBg command
  vim.api.nvim_create_user_command('ClaudeBg', function(opts)
    M.claude_bg(opts.args)
  end, {
    desc = 'Start a background Claude agent',
    nargs = '*', -- Changed from '+' to '*' to allow zero arguments
    complete = function()
      return {}
    end,
  })

  -- Checkpoint commands
  vim.api.nvim_create_user_command('ClaudeCheckpoints', function()
    M.open_checkpoints()
  end, {
    desc = 'Open checkpoint browser',
  })

  vim.api.nvim_create_user_command('ClaudeCheckpointCreate', function(opts)
    M.create_checkpoint(opts.args)
  end, {
    desc = 'Create a checkpoint manually',
    nargs = '?',
  })

  vim.api.nvim_create_user_command('ClaudeCheckpointRestore', function(opts)
    M.restore_checkpoint(opts.args)
  end, {
    desc = 'Restore a specific checkpoint',
    nargs = 1,
  })

  vim.api.nvim_create_user_command('ClaudeCheckpointStatus', function()
    M.checkpoint_status()
  end, {
    desc = 'Show current checkpoint status',
  })

  vim.api.nvim_create_user_command('ClaudeCheckpointAccept', function()
    M.accept_checkpoint()
  end, {
    desc = 'Accept current preview checkpoint',
  })

  vim.api.nvim_create_user_command('ClaudeCheckpointReturn', function()
    M.return_from_checkpoint()
  end, {
    desc = 'Return to original state (exit preview)',
  })

  -- ClaudeAgents command
  vim.api.nvim_create_user_command('ClaudeAgents', function()
    M.list_agents()
  end, {
    desc = 'List all Claude agents',
  })

  -- ClaudeRebuildRegistry command
  vim.api.nvim_create_user_command('ClaudeRebuildRegistry', function()
    M.rebuild_agent_registry()
  end, {
    desc = 'Rebuild agent registry from existing directories',
  })

  -- ClaudeKill command
  vim.api.nvim_create_user_command('ClaudeKill', function(opts)
    M.kill_agent(opts.args)
  end, {
    desc = 'Kill a Claude agent',
    nargs = '?',
    complete = function()
      local agents = claude.registry.get_project_agents()
      local completions = {}
      for id, agent in pairs(agents) do
        if agent.status == 'active' then
          table.insert(completions, id)
        end
      end
      return completions
    end,
  })

  -- ClaudeKillAll command
  vim.api.nvim_create_user_command('ClaudeKillAll', function()
    M.kill_all_agents()
  end, {
    desc = 'Kill all active Claude agents',
  })

  -- ClaudeClean command
  vim.api.nvim_create_user_command('ClaudeClean', function()
    M.clean_agents()
  end, {
    desc = 'Clean up old Claude agents',
  })

  -- ClaudeDebug command
  vim.api.nvim_create_user_command('ClaudeDebug', function()
    M.debug_panes()
  end, {
    desc = 'Debug Claude pane detection',
  })

  -- ClaudeSwitch command (DEPRECATED - use ClaudeAgents instead)
  vim.api.nvim_create_user_command('ClaudeSwitch', function(opts)
    vim.notify('ClaudeSwitch is deprecated. Use :ClaudeAgents instead.', vim.log.levels.WARN)
    -- Redirect to ClaudeAgents
    M.list_agents()
  end, {
    desc = '[DEPRECATED] Use :ClaudeAgents instead',
    nargs = '?',
  })

  -- ClaudeDebugAgents command
  vim.api.nvim_create_user_command('ClaudeDebugAgents', function()
    local current_dir = vim.fn.getcwd()
    local project_root = claude.utils.get_project_root()
    local all_agents = claude.registry.agents
    local project_agents = claude.registry.get_project_agents()

    vim.notify(string.format('Current directory: %s', current_dir), vim.log.levels.INFO)
    vim.notify(string.format('Project root: %s', project_root), vim.log.levels.INFO)
    vim.notify(string.format('Total agents in registry: %d', vim.tbl_count(all_agents)), vim.log.levels.INFO)
    vim.notify(string.format('Project agents count: %d', #project_agents), vim.log.levels.INFO)

    for id, agent in pairs(all_agents) do
      vim.notify(
        string.format(
          '  Agent %s: project=%s, status=%s, task=%s',
          id,
          agent.project_root or 'nil',
          agent.status,
          (agent.task or ''):match '[^\n]*' or agent.task
        ),
        vim.log.levels.INFO
      )
    end
  end, {
    desc = 'Debug agent registry',
  })

  -- ClaudeCleanOrphans command - clean orphaned directories
  vim.api.nvim_create_user_command('ClaudeCleanOrphans', function()
    M.clean_orphaned_directories()
  end, {
    desc = 'Clean orphaned agent directories',
  })

  -- ClaudeDiffAgent command
  vim.api.nvim_create_user_command('ClaudeDiffAgent', function(opts)
    M.diff_agent(opts.args ~= '' and opts.args or nil)
  end, {
    desc = 'Review agent changes with diffview',
    nargs = '?',
    complete = function()
      local agents = claude.registry.get_project_agents()
      local completions = {}
      for _, agent in ipairs(agents) do
        table.insert(completions, agent.id)
      end
      return completions
    end,
  })

  vim.api.nvim_create_user_command('ClaudeViewLog', function()
    local logger = require 'nvim-claude.logger'
    local log_file = logger.get_log_file()

    -- Check if log file exists
    if vim.fn.filereadable(log_file) == 1 then
      vim.cmd('edit ' .. log_file)
      vim.cmd 'normal! G' -- Go to end of file
    else
      vim.notify('No log file found at: ' .. log_file, vim.log.levels.INFO)
    end
  end, {
    desc = 'View nvim-claude debug log',
  })

  vim.api.nvim_create_user_command('ClaudeClearLog', function()
    local logger = require 'nvim-claude.logger'
    logger.clear()
    vim.notify('Debug log cleared', vim.log.levels.INFO)
  end, {
    desc = 'Clear nvim-claude debug log',
  })

  -- Debug command to check registry state
  vim.api.nvim_create_user_command('ClaudeDebugRegistry', function()
    local project_root = claude.utils.get_project_root()
    local current_dir = vim.fn.getcwd()
    local all_agents = claude.registry.agents
    local project_agents = claude.registry.get_project_agents()

    vim.notify('=== Claude Registry Debug ===', vim.log.levels.INFO)
    vim.notify('Current directory: ' .. current_dir, vim.log.levels.INFO)
    vim.notify('Project root: ' .. project_root, vim.log.levels.INFO)
    vim.notify('Total agents in registry: ' .. vim.tbl_count(all_agents), vim.log.levels.INFO)
    vim.notify('Agents for current project: ' .. #project_agents, vim.log.levels.INFO)

    if vim.tbl_count(all_agents) > 0 then
      vim.notify('\nAll agents:', vim.log.levels.INFO)
      for id, agent in pairs(all_agents) do
        vim.notify(string.format('  %s: project_root=%s, work_dir=%s', id, agent.project_root, agent.work_dir), vim.log.levels.INFO)
      end
    end
  end, {
    desc = 'Debug Claude registry state',
  })

  -- ClaudeShowMCPCommand - show MCP setup instructions
  vim.api.nvim_create_user_command('ClaudeShowMCPCommand', function()
    require('nvim-claude').show_mcp_setup_command()
  end, { desc = 'Show MCP server setup command' })

  -- ClaudeListProjects - list all tracked projects
  vim.api.nvim_create_user_command('ClaudeListProjects', function()
    local project_state = require 'nvim-claude.project-state'
    local projects = project_state.list_projects()

    if #projects == 0 then
      vim.notify('No tracked projects found', vim.log.levels.INFO)
      return
    end

    vim.notify('=== Tracked Projects ===', vim.log.levels.INFO)
    for _, proj in ipairs(projects) do
      local status = proj.exists and '✓' or '✗'
      local features = {}
      if proj.has_inline_diff then
        table.insert(features, 'diffs')
      end
      if proj.has_agents then
        table.insert(features, 'agents')
      end
      local feature_str = #features > 0 and ' [' .. table.concat(features, ', ') .. ']' or ''

      vim.notify(string.format('%s %s - %s%s', status, os.date('%Y-%m-%d', proj.last_accessed), proj.path, feature_str), vim.log.levels.INFO)
    end
  end, { desc = 'List all tracked projects' })

  -- ClaudeCleanupProjects - clean up old project states
  vim.api.nvim_create_user_command('ClaudeCleanupProjects', function(opts)
    local days = tonumber(opts.args) or 30
    local project_state = require 'nvim-claude.project-state'
    local removed = project_state.cleanup_old_projects(days)

    vim.notify(string.format('Cleaned up %d old project state%s (older than %d days)', removed, removed ~= 1 and 's' or '', days), vim.log.levels.INFO)
  end, {
    desc = 'Clean up old project states',
    nargs = '?',
  })

  -- ClaudeDebugInstall command to help diagnose installation issues
  vim.api.nvim_create_user_command('ClaudeDebugInstall', function()
    local nvim_claude = require 'nvim-claude'
    vim.notify('=== nvim-claude Installation Debug ===', vim.log.levels.INFO)

    -- Show Neovim data paths
    vim.notify('Neovim data path: ' .. vim.fn.stdpath 'data', vim.log.levels.INFO)

    -- Check common plugin locations
    local locations = {
      { name = 'lazy.nvim', path = vim.fn.stdpath 'data' .. '/lazy/nvim-claude/' },
      { name = 'packer', path = vim.fn.stdpath 'data' .. '/site/pack/packer/start/nvim-claude/' },
      { name = 'development', path = vim.fn.expand '~/.config/nvim/lua/nvim-claude/' },
    }

    for _, loc in ipairs(locations) do
      local exists = vim.fn.isdirectory(loc.path) == 1
      local has_mcp = vim.fn.isdirectory(loc.path .. 'mcp-server') == 1
      vim.notify(string.format('%s: %s (mcp-server: %s)', loc.name, exists and 'found' or 'not found', has_mcp and 'yes' or 'no'), vim.log.levels.INFO)
    end

    -- Try to find plugin directory
    local plugin_dir = nvim_claude.get_plugin_dir()
    if plugin_dir then
      vim.notify('\nDetected plugin directory: ' .. plugin_dir, vim.log.levels.INFO)
    else
      vim.notify('\nCould not detect plugin directory', vim.log.levels.ERROR)
    end

    -- Check MCP installation
    local venv_path = vim.fn.expand '~/.local/share/nvim/nvim-claude/mcp-env'
    local venv_exists = vim.fn.isdirectory(venv_path) == 1
    vim.notify('\nMCP venv: ' .. (venv_exists and 'installed' or 'not installed'), vim.log.levels.INFO)
    if venv_exists then
      local python_exists = vim.fn.filereadable(venv_path .. '/bin/python') == 1
      vim.notify('Python executable: ' .. (python_exists and 'found' or 'not found'), vim.log.levels.INFO)
    end
  end, { desc = 'Debug nvim-claude installation' })

  -- ClaudeInstallMCP command
  vim.api.nvim_create_user_command('ClaudeInstallMCP', function()
    -- Get plugin directory using shared function from init.lua
    local plugin_dir = require('nvim-claude').get_plugin_dir()
    if not plugin_dir then
      vim.notify('nvim-claude: Could not find plugin directory. Please report this issue.', vim.log.levels.ERROR)
      return
    end

    local install_script = plugin_dir .. 'mcp-server/install.sh'

    -- Check if install script exists
    if vim.fn.filereadable(install_script) == 0 then
      vim.notify('nvim-claude: MCP install script not found at: ' .. install_script, vim.log.levels.ERROR)
      return
    end

    local function on_exit(job_id, code, event)
      if code == 0 then
        vim.notify('✅ MCP server installed successfully!', vim.log.levels.INFO)
        vim.notify('Run "claude mcp list" to verify installation', vim.log.levels.INFO)
      else
        vim.notify('❌ MCP installation failed. Check :messages for details', vim.log.levels.ERROR)
      end
    end

    vim.notify('Installing MCP server dependencies...', vim.log.levels.INFO)
    vim.fn.jobstart({ 'bash', install_script }, {
      on_exit = on_exit,
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= '' then
            print(line)
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if line ~= '' then
            vim.notify(line, vim.log.levels.WARN)
          end
        end
      end,
    })
  end, { desc = 'Install Claude MCP server dependencies' })

  -- ClaudeInstallRPC command
  vim.api.nvim_create_user_command('ClaudeInstallRPC', function()
    -- Get plugin directory using shared function from init.lua
    local plugin_dir = require('nvim-claude').get_plugin_dir()
    if not plugin_dir then
      vim.notify('nvim-claude: Could not find plugin directory. Please report this issue.', vim.log.levels.ERROR)
      return
    end

    local install_script = plugin_dir .. 'scripts/install-rpc.sh'

    -- Check if install script exists
    if vim.fn.filereadable(install_script) == 0 then
      vim.notify('nvim-claude: RPC install script not found at: ' .. install_script, vim.log.levels.ERROR)
      return
    end

    local function on_exit(job_id, code, event)
      if code == 0 then
        vim.notify('✅ RPC client installed successfully!', vim.log.levels.INFO)
        vim.notify('Hooks will now use the Python RPC client', vim.log.levels.INFO)
      else
        vim.notify('❌ RPC installation failed. Check :messages for details', vim.log.levels.ERROR)
      end
    end

    vim.notify('Installing RPC client dependencies...', vim.log.levels.INFO)
    vim.fn.jobstart({ 'bash', install_script }, {
      on_exit = on_exit,
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= '' then
            print(line)
          end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if line ~= '' then
            vim.notify(line, vim.log.levels.WARN)
          end
        end
      end,
    })
  end, { desc = 'Install nvim-claude RPC client (pynvim)' })

  -- ClaudeSendWithDiagnostics command (visual mode)
  vim.api.nvim_create_user_command('ClaudeSendWithDiagnostics', function(args)
    M.send_selection_with_diagnostics(args.line1, args.line2)
  end, {
    desc = 'Send selected text with diagnostics to Claude',
    range = true,
  })
end

-- Open Claude chat
function M.claude_chat()
  if not claude.tmux.validate() then
    return
  end

  local pane_id = claude.tmux.create_pane 'claude'
  if pane_id then
    vim.notify('Claude chat opened in pane ' .. pane_id, vim.log.levels.INFO)
  else
    vim.notify('Failed to create Claude pane', vim.log.levels.ERROR)
  end
end

-- Send current buffer to Claude
function M.send_buffer()
  if not claude.tmux.validate() then
    return
  end

  local pane_id = claude.tmux.find_claude_pane()
  if not pane_id then
    pane_id = claude.tmux.create_pane 'claude'
  end

  if not pane_id then
    vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR)
    return
  end

  -- Get buffer info
  local filename = vim.fn.expand '%:t'
  local filetype = vim.bo.filetype
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  -- Build complete message as one string
  local message_parts = {
    string.format('Here is `%s` (%s):', filename, filetype),
    '```' .. (filetype ~= '' and filetype or ''),
  }

  -- Add all lines
  for _, line in ipairs(lines) do
    table.insert(message_parts, line)
  end

  table.insert(message_parts, '```')

  -- Send as one batched message
  local full_message = table.concat(message_parts, '\n')
  claude.tmux.send_text_to_pane(pane_id, full_message)

  vim.notify('Buffer sent to Claude', vim.log.levels.INFO)
end

-- Send selection to Claude
function M.send_selection(line1, line2)
  if not claude.tmux.validate() then
    return
  end

  local pane_id = claude.tmux.find_claude_pane()
  if not pane_id then
    pane_id = claude.tmux.create_pane 'claude'
  end

  if not pane_id then
    vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR)
    return
  end

  -- Get selected lines
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)

  -- Get relative path from git root
  local git_root = claude.utils.get_project_root()
  local file_path = vim.fn.expand '%:p'
  local relative_path = git_root and file_path:gsub('^' .. vim.pesc(git_root) .. '/', '') or vim.fn.expand '%:t'

  -- Build complete message as one string
  local filetype = vim.bo.filetype
  local message_parts = {
    string.format('Selection from `%s` (lines %d-%d):', relative_path, line1, line2),
    '```' .. (filetype ~= '' and filetype or ''),
  }

  -- Add all lines
  for _, line in ipairs(lines) do
    table.insert(message_parts, line)
  end

  table.insert(message_parts, '```')

  -- Send as one batched message
  local full_message = table.concat(message_parts, '\n')
  claude.tmux.send_text_to_pane(pane_id, full_message)

  -- Switch focus to Claude pane
  claude.utils.exec('tmux select-pane -t ' .. pane_id)

  vim.notify('Selection sent to Claude', vim.log.levels.INFO)
end

-- Send selection with diagnostics to Claude
function M.send_selection_with_diagnostics(line1, line2)
  if not claude.tmux.validate() then
    return
  end

  local pane_id = claude.tmux.find_claude_pane()
  if not pane_id then
    pane_id = claude.tmux.create_pane 'claude'
  end

  if not pane_id then
    vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR)
    return
  end

  -- Get selected lines
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  local code = table.concat(lines, '\n')

  -- Get relative path from git root
  local git_root = claude.utils.get_project_root()
  local file_path = vim.fn.expand '%:p'
  local file = git_root and file_path:gsub('^' .. vim.pesc(git_root) .. '/', '') or vim.fn.expand '%:t'

  -- Get diagnostics for selected range
  local all_diagnostics = vim.diagnostic.get(0)
  local diagnostics = {}

  -- Filter diagnostics to only include those in the selected range
  for _, diag in ipairs(all_diagnostics) do
    if diag.lnum >= line1 - 1 and diag.lnum <= line2 - 1 then
      table.insert(diagnostics, diag)
    end
  end

  -- Format diagnostics
  local diagnostics_text = M.format_diagnostics_list(diagnostics)

  -- Build complete message
  local filetype = vim.bo.filetype
  local message = string.format(
    [[
I have a code snippet with LSP diagnostics that need to be fixed:

File: %s
Lines: %d-%d

```%s
%s
```

LSP Diagnostics:
%s

Please help me fix these issues.]],
    file,
    line1,
    line2,
    filetype ~= '' and filetype or '',
    code,
    diagnostics_text
  )

  -- Send message
  claude.tmux.send_text_to_pane(pane_id, message)

  -- Switch focus to Claude pane
  claude.utils.exec('tmux select-pane -t ' .. pane_id)

  vim.notify('Selection with diagnostics sent to Claude', vim.log.levels.INFO)
end

-- Helper function to format diagnostics list
function M.format_diagnostics_list(diagnostics)
  if #diagnostics == 0 then
    return 'No diagnostics in selected range'
  end

  local lines = {}
  for _, d in ipairs(diagnostics) do
    local severity = vim.diagnostic.severity[d.severity]
    table.insert(lines, string.format('- Line %d, Col %d [%s]: %s', d.lnum + 1, d.col + 1, severity, d.message))
  end
  return table.concat(lines, '\n')
end

-- Send git hunk under cursor to Claude
function M.send_hunk()
  if not claude.tmux.validate() then
    return
  end

  local pane_id = claude.tmux.find_claude_pane()
  if not pane_id then
    pane_id = claude.tmux.create_pane 'claude'
  end

  if not pane_id then
    vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR)
    return
  end

  -- Get current cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor_pos[1]

  -- Get git diff to find hunks
  local filename = vim.fn.expand '%:p'
  local relative_filename = vim.fn.expand '%'

  if not filename or filename == '' then
    vim.notify('No file to get hunk from', vim.log.levels.ERROR)
    return
  end

  -- Get git diff for this file
  local cmd = string.format('git diff HEAD -- "%s"', filename)
  local diff_output = claude.utils.exec(cmd)

  if not diff_output or diff_output == '' then
    vim.notify('No git changes found in current file', vim.log.levels.INFO)
    return
  end

  -- Parse diff to find hunk containing current line
  local hunk_lines = {}
  local hunk_start = nil
  local hunk_end = nil
  local found_hunk = false

  for line in diff_output:gmatch '[^\n]+' do
    if line:match '^@@' then
      -- Parse hunk header: @@ -oldstart,oldcount +newstart,newcount @@
      local newstart, newcount = line:match '^@@ %-%d+,%d+ %+(%d+),(%d+) @@'
      if newstart and newcount then
        newstart = tonumber(newstart)
        newcount = tonumber(newcount)

        if current_line >= newstart and current_line < newstart + newcount then
          found_hunk = true
          hunk_start = newstart
          hunk_end = newstart + newcount - 1
          table.insert(hunk_lines, line) -- Include the @@ line
        else
          found_hunk = false
          hunk_lines = {}
        end
      end
    elseif found_hunk then
      table.insert(hunk_lines, line)
    end
  end

  if #hunk_lines == 0 then
    vim.notify('No git hunk found at cursor position', vim.log.levels.INFO)
    return
  end

  -- Build message
  local message_parts = {
    string.format('Git hunk from `%s` (around line %d):', relative_filename, current_line),
    '```diff',
  }

  -- Add hunk lines
  for _, line in ipairs(hunk_lines) do
    table.insert(message_parts, line)
  end

  table.insert(message_parts, '```')

  -- Send as one batched message
  local full_message = table.concat(message_parts, '\n')
  claude.tmux.send_text_to_pane(pane_id, full_message)

  vim.notify('Git hunk sent to Claude', vim.log.levels.INFO)
end

-- Start background agent with UI
function M.claude_bg(task)
  if not claude.tmux.validate() then
    return
  end

  -- If task provided via command line, use old flow for backwards compatibility
  if task and task ~= '' then
    M.create_agent_from_task(task, nil)
    return
  end

  -- Otherwise show the new UI
  M.show_agent_creation_ui()
end

-- Show agent creation UI
function M.show_agent_creation_ui()
  -- Start with mission input stage
  M.show_mission_input_ui()
end

-- Stage 1: Mission input with multiline support
function M.show_mission_input_ui()
  -- Create buffer for mission input
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown') -- Nice syntax highlighting

  -- Initial content with placeholder
  local lines = {
    '# Agent Mission Description',
    '',
    'Enter your detailed mission description below.',
    'You can use multiple lines and markdown formatting.',
    '',
    '## Task:',
    '',
    '(Type your task here...)',
    '',
    '## Goals:',
    '- ',
    '',
    '## Notes:',
    '- ',
    '',
    '',
    '────────────────────────────────────────',
    'Press <Tab> to continue to fork options',
    'Press <Esc> to cancel',
  }

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Create window
  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(25, vim.o.lines - 6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Agent Mission (Step 1/3) ',
    title_pos = 'center',
  })

  -- Set telescope-like highlights
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')

  -- Position cursor at task area
  vim.api.nvim_win_set_cursor(win, { 8, 0 })

  -- Function to extract mission from buffer
  local function get_mission()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local mission_lines = {}
    local in_content = false

    for _, line in ipairs(all_lines) do
      -- Stop at the separator line
      if line:match '^────' then
        break
      end

      -- Skip only the main header and instruction lines
      if line:match '^# Agent Mission' or line:match '^Enter your detailed' or line:match '^You can use multiple' then
        -- Skip these lines
      else
        -- Include everything else (including ## Task:, ## Goals:, ## Notes:)
        if line ~= '' or in_content then
          in_content = true
          table.insert(mission_lines, line)
        end
      end
    end

    -- Clean up the mission text
    local mission = table.concat(mission_lines, '\n'):gsub('^%s*(.-)%s*$', '%1')
    -- Remove placeholder text
    mission = mission:gsub('%(Type your task here%.%.%.%)', '')
    return mission
  end

  -- Function to proceed to fork selection
  local function proceed_to_fork_selection()
    local mission = get_mission()
    if mission == '' or mission:match '^%s*$' then
      vim.notify('Please enter a mission description', vim.log.levels.ERROR)
      return
    end

    -- Close current window
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end

    -- Proceed to fork selection
    local state = {
      fork_option = 1,
      mission = mission,
    }
    M.show_fork_options_ui(state)
  end

  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Set up keymaps
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Tab>', '', {
    callback = proceed_to_fork_selection,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'i', '<Tab>', '', {
    callback = proceed_to_fork_selection,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', {
    callback = close_window,
    silent = true,
  })

  -- Start in insert mode at the task area
  vim.cmd 'startinsert'
end

-- Show fork options UI with telescope-like styling
function M.show_fork_options_ui(state)
  -- Ensure we're in normal mode when showing this UI
  vim.cmd 'stopinsert'

  local default_branch = claude.git.default_branch()
  local options = {
    { label = 'Current branch', desc = 'Fork from your current branch state', value = 1 },
    { label = default_branch .. ' branch', desc = 'Start fresh from ' .. default_branch .. ' branch', value = 2 },
    { label = 'Stash current changes', desc = 'Include your uncommitted changes', value = 3 },
    { label = 'Other branch...', desc = 'Choose any branch to fork from', value = 4 },
  }

  -- Create buffer for options
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  -- Create lines for display
  local lines = {}
  -- Handle multiline mission by showing first line only
  local mission_first_line = state.mission:match '[^\n]*' or state.mission
  local mission_preview = mission_first_line:sub(1, 60) .. (mission_first_line:len() > 60 and '...' or '')
  table.insert(lines, string.format('Mission: %s', mission_preview))
  table.insert(lines, '')
  table.insert(lines, 'Select fork option:')
  table.insert(lines, '')

  for i, option in ipairs(options) do
    local icon = i == state.fork_option and '▶' or ' '
    table.insert(lines, string.format('%s %d. %s', icon, i, option.label))
    table.insert(lines, string.format('   %s', option.desc))
    table.insert(lines, '')
  end

  table.insert(lines, 'Press <Tab> to configure setup instructions, <S-Tab> to go back, q to cancel')

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Create window with telescope-like styling
  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 4, vim.o.lines - 10)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Fork Options (Step 2/3) ',
    title_pos = 'center',
  })

  -- Set telescope-like highlights
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')

  -- Function to update the display
  local function update_display()
    local updated_lines = {}
    -- Handle multiline mission by showing first line only
    local mission_first_line = state.mission:match '[^\n]*' or state.mission
    local mission_preview = mission_first_line:sub(1, 60) .. (mission_first_line:len() > 60 and '...' or '')
    table.insert(updated_lines, string.format('Mission: %s', mission_preview))
    table.insert(updated_lines, '')
    table.insert(updated_lines, 'Select fork option:')
    table.insert(updated_lines, '')

    for i, option in ipairs(options) do
      local icon = i == state.fork_option and '▶' or ' '
      table.insert(updated_lines, string.format('%s %d. %s', icon, i, option.label))
      table.insert(updated_lines, string.format('   %s', option.desc))
      table.insert(updated_lines, '')
    end

    table.insert(updated_lines, 'Press <Tab> to configure setup instructions, q to cancel')

    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, updated_lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  end

  -- Create agent with selected options
  local function create_agent()
    -- Close the window
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end

    -- Handle fork option
    local fork_from = nil
    local default_branch = claude.git.default_branch()
    if state.fork_option == 1 then
      -- Current branch (default)
      fork_from = { type = 'branch', branch = claude.git.current_branch() or default_branch }
    elseif state.fork_option == 2 then
      -- Default branch (main/master)
      fork_from = { type = 'branch', branch = default_branch }
    elseif state.fork_option == 3 then
      -- Stash current changes
      fork_from = { type = 'stash' }
    elseif state.fork_option == 4 then
      -- Other branch - show branch selection
      -- Ensure we're in normal mode before transitioning
      vim.cmd 'stopinsert'
      -- Close the fork options window first
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      vim.schedule(function()
        M.show_branch_selection(function(branch)
          if branch then
            fork_from = { type = 'branch', branch = branch }
            M.show_setup_instructions_ui(state, function()
              M.create_agent_from_task(state.mission, fork_from, state.setup_commands)
            end)
          end
        end)
      end)
      return
    end

    -- Show setup instructions stage
    M.show_setup_instructions_ui(state, function()
      M.create_agent_from_task(state.mission, fork_from, state.setup_commands)
    end)
  end

  -- Navigation functions
  local function move_up()
    if state.fork_option > 1 then
      state.fork_option = state.fork_option - 1
      update_display()
    end
  end

  local function move_down()
    if state.fork_option < #options then
      state.fork_option = state.fork_option + 1
      update_display()
    end
  end

  -- Set up keymaps
  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Number keys
  for i = 1, #options do
    vim.api.nvim_buf_set_keymap(buf, 'n', tostring(i), '', {
      callback = function()
        state.fork_option = i
        update_display()
      end,
      silent = true,
    })
  end

  -- Navigation keys
  vim.api.nvim_buf_set_keymap(buf, 'n', 'j', '', { callback = move_down, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', 'k', '', { callback = move_up, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Down>', '', { callback = move_down, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Up>', '', { callback = move_up, silent = true })

  -- Go back to mission editor
  local function go_back()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Re-show mission UI with the current mission
    M.show_mission_input_ui()
  end
  
  -- Action keys
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Tab>', '', { callback = create_agent, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<S-Tab>', '', { callback = go_back, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', { callback = close_window, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', { callback = close_window, silent = true })
end

-- Show branch selection UI
function M.show_branch_selection(callback)
  -- Get list of branches
  local branches_output = claude.utils.exec 'git branch -a'
  if not branches_output then
    vim.notify('Failed to get branches', vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local branches = {}
  for line in branches_output:gmatch '[^\n]+' do
    local branch = line:match '^%s*%*?%s*(.+)$'
    if branch and not branch:match 'HEAD detached' then
      -- Clean up remote branch names
      branch = branch:gsub('^remotes/origin/', '')
      table.insert(branches, branch)
    end
  end

  -- Remove duplicates
  local seen = {}
  local unique_branches = {}
  for _, branch in ipairs(branches) do
    if not seen[branch] then
      seen[branch] = true
      table.insert(unique_branches, branch)
    end
  end

  -- Create custom branch selection UI
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  -- State for current selection
  local state = {
    selected = 1
  }

  -- Function to update display
  local function update_display()
    local lines = { 'Select branch to fork from:', '' }
    
    for i, branch in ipairs(unique_branches) do
      local icon = i == state.selected and '▶' or ' '
      table.insert(lines, string.format('%s %s', icon, branch))
    end

    table.insert(lines, '')
    table.insert(lines, 'Press <Tab> to select, <Esc> to cancel')
    table.insert(lines, 'Use j/k or arrow keys to navigate')

    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  end

  -- Initial display
  update_display()

  -- Create window
  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#unique_branches + 6, vim.o.lines - 6)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Branch Selection ',
    title_pos = 'center',
  })

  -- Set telescope-like highlights
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')

  -- Ensure we start in normal mode
  vim.cmd 'stopinsert'

  -- Function to move selection
  local function move_selection(delta)
    state.selected = math.max(1, math.min(#unique_branches, state.selected + delta))
    update_display()
  end

  -- Function to select current branch
  local function select_current()
    local branch = unique_branches[state.selected]
    vim.api.nvim_win_close(win, true)
    callback(branch)
  end

  -- Function to close window
  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    callback(nil)
  end

  -- Set up keymaps
  -- Navigation
  vim.api.nvim_buf_set_keymap(buf, 'n', 'j', '', {
    callback = function() move_selection(1) end,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', 'k', '', {
    callback = function() move_selection(-1) end,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Down>', '', {
    callback = function() move_selection(1) end,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Up>', '', {
    callback = function() move_selection(-1) end,
    silent = true,
  })

  -- Selection
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Tab>', '', {
    callback = select_current,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', '', {
    callback = select_current,
    silent = true,
  })

  -- Number key mappings for quick selection
  for i = 1, math.min(9, #unique_branches) do
    vim.api.nvim_buf_set_keymap(buf, 'n', tostring(i), '', {
      callback = function()
        state.selected = i
        update_display()
        select_current()
      end,
      silent = true,
    })
  end

  -- Cancel
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', {
    callback = close_window,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
    callback = close_window,
    silent = true,
  })
end

-- Format task string into sections
function M.format_task_sections(task_string)
  local formatted = {}
  
  -- Extract each section using more precise patterns
  local task_match = task_string:match('## Task:%s*\n(.-)\n%s*## Goals:')
  local goals_match = task_string:match('## Goals:%s*\n(.-)\n%s*## Notes:')
  local notes_match = task_string:match('## Notes:%s*\n(.*)$')
  
  -- Process Task section
  if task_match then
    local cleaned = task_match:gsub('^%s*', ''):gsub('%s*$', '')
    if cleaned ~= '' and cleaned ~= '-' then
      table.insert(formatted, '# Task')
      table.insert(formatted, cleaned)
    end
  end
  
  -- Process Goals section
  if goals_match then
    local cleaned = goals_match:gsub('^%s*', ''):gsub('%s*$', '')
    -- Skip if it's just a dash with optional whitespace
    if cleaned ~= '' and cleaned ~= '-' and not cleaned:match('^%-%s*$') then
      if #formatted > 0 then table.insert(formatted, '') end
      table.insert(formatted, '# Goals')
      table.insert(formatted, cleaned)
    end
  end
  
  -- Process Notes section
  if notes_match then
    local cleaned = notes_match:gsub('^%s*', ''):gsub('%s*$', '')
    -- Skip if it's just a dash with optional whitespace
    if cleaned ~= '' and cleaned ~= '-' and not cleaned:match('^%-%s*$') then
      if #formatted > 0 then table.insert(formatted, '') end
      table.insert(formatted, '# Notes')
      table.insert(formatted, cleaned)
    end
  end
  
  -- If no sections found, treat entire string as task
  if #formatted == 0 then
    local cleaned = task_string:gsub('^%s+', ''):gsub('%s+$', '')
    if cleaned ~= '' then
      table.insert(formatted, '# Task')
      table.insert(formatted, cleaned)
    end
  end
  
  return table.concat(formatted, '\n')
end

-- Detect setup commands for a project
function M.detect_setup_commands(project_root)
  local commands = {}

  -- Check for environment files in project root
  if claude.utils.file_exists(project_root .. '/.env') then
    table.insert(commands, '# Copy environment config from main project')
    table.insert(commands, 'cp ../../.env .')
  end
  if claude.utils.file_exists(project_root .. '/.env.local') then
    table.insert(commands, 'cp ../../.env.local .')
  end

  -- Check for package managers
  if claude.utils.file_exists(project_root .. '/pnpm-lock.yaml') then
    table.insert(commands, '')
    table.insert(commands, '# Install dependencies')
    table.insert(commands, 'pnpm install')
  elseif claude.utils.file_exists(project_root .. '/yarn.lock') then
    table.insert(commands, '')
    table.insert(commands, '# Install dependencies')
    table.insert(commands, 'yarn install')
  elseif claude.utils.file_exists(project_root .. '/package-lock.json') then
    table.insert(commands, '')
    table.insert(commands, '# Install dependencies')
    table.insert(commands, 'npm install')
  elseif claude.utils.file_exists(project_root .. '/package.json') then
    table.insert(commands, '')
    table.insert(commands, '# Install dependencies (no lock file found)')
    table.insert(commands, 'npm install')
  end

  -- Check for Python projects
  if claude.utils.file_exists(project_root .. '/requirements.txt') then
    table.insert(commands, '')
    table.insert(commands, '# Install Python dependencies')
    table.insert(commands, 'pip install -r requirements.txt')
  elseif claude.utils.file_exists(project_root .. '/pyproject.toml') then
    table.insert(commands, '')
    table.insert(commands, '# Install Python project')
    table.insert(commands, 'pip install -e .')
  end

  -- Check for build scripts in package.json
  if claude.utils.file_exists(project_root .. '/package.json') then
    local package_json = vim.fn.readfile(project_root .. '/package.json')
    local content = table.concat(package_json, '\n')
    if content:match '"build"' then
      table.insert(commands, '')
      table.insert(commands, '# Build the project')
      local pkg_manager = 'npm'
      if claude.utils.file_exists(project_root .. '/pnpm-lock.yaml') then
        pkg_manager = 'pnpm'
      elseif claude.utils.file_exists(project_root .. '/yarn.lock') then
        pkg_manager = 'yarn'
      end
      table.insert(commands, pkg_manager .. ' run build')
    end
  end

  -- Check for Makefile with setup target
  if claude.utils.file_exists(project_root .. '/Makefile') then
    local makefile = vim.fn.readfile(project_root .. '/Makefile')
    local content = table.concat(makefile, '\n')
    if content:match '^setup:' then
      table.insert(commands, '')
      table.insert(commands, '# Run Makefile setup')
      table.insert(commands, 'make setup')
    end
  end

  return commands
end

-- Load setup history for a project
function M.load_setup_history(project_root)
  local project_state = require 'nvim-claude.project-state'
  local state = project_state.get_project_state(project_root)
  return state and state.agent_setup_history or nil
end

-- Save setup history for a project
function M.save_setup_history(project_root, commands)
  local project_state = require 'nvim-claude.project-state'
  project_state.save_project_state(project_root, {
    agent_setup_history = {
      last_used = os.date '!%Y-%m-%dT%H:%M:%SZ',
      setup_commands = commands,
    },
  })
end

-- Show setup instructions UI
function M.show_setup_instructions_ui(state, callback)
  -- Create buffer for setup instructions
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'bash')

  -- Create window first to get width
  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(25, vim.o.lines - 6)

  -- Create divider based on window width
  local divider = string.rep('━', width)

  -- Get setup commands
  local project_root = claude.utils.get_project_root()
  local commands = state.setup_commands
  if not commands then
    local history = M.load_setup_history(project_root)
    if history and history.setup_commands then
      commands = history.setup_commands
    else
      commands = M.detect_setup_commands(project_root)
    end
  end

  -- Build content
  local lines = {
    divider,
    ' Agent Setup Instructions',
    divider,
    '',
    'The agent will need to set up the worktree environment.',
    'Edit the commands below as needed:',
    '',
  }

  -- Add commands
  for _, cmd in ipairs(commands) do
    table.insert(lines, cmd)
  end

  -- Add footer
  table.insert(lines, '')
  table.insert(lines, '# Additional setup')
  table.insert(lines, '# (add any other setup commands here)')
  table.insert(lines, '')
  table.insert(lines, divider)
  table.insert(lines, 'Press <Tab> to start agent · <S-Tab> to go back · <Esc> to cancel')
  table.insert(lines, divider)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Setup Instructions (Step 3/3) ',
    title_pos = 'center',
  })

  -- Set cursor to first editable line
  vim.api.nvim_win_set_cursor(win, { 8, 0 })

  -- Function to extract commands
  local function extract_commands()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local extracted = {}
    local in_commands = false

    for i, line in ipairs(all_lines) do
      if line:match '^━+$' then  -- Match any number of ━ characters
        if in_commands then
          break
        end
      elseif line:match 'Agent Setup Instructions' then
        in_commands = true
      elseif in_commands and line ~= '' and not line:match '^The agent will' and not line:match '^Edit the commands' then
        table.insert(extracted, line)
      end
    end

    return extracted
  end

  -- Continue function
  local function continue()
    state.setup_commands = extract_commands()
    vim.api.nvim_win_close(win, true)

    -- Save for next time
    M.save_setup_history(project_root, state.setup_commands)

    -- Continue with callback
    if callback then
      callback()
    end
  end

  -- Cancel function
  local function cancel()
    vim.api.nvim_win_close(win, true)
  end
  
  -- Go back to fork options
  local function go_back()
    vim.api.nvim_win_close(win, true)
    -- Re-show fork options with the current state
    M.show_fork_options_ui(state)
  end

  -- Set up keymaps
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Tab>', '', {
    callback = continue,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'i', '<Tab>', '', {
    callback = continue,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<S-Tab>', '', {
    callback = go_back,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'i', '<S-Tab>', '', {
    callback = go_back,
    silent = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', {
    callback = cancel,
    silent = true,
  })
end

-- Create agent from task and fork options
function M.create_agent_from_task(task, fork_from, setup_commands)
  if not claude.tmux.validate() then
    return
  end

  -- Create agent work directory
  local project_root = claude.utils.get_project_root()
  local work_dir = project_root .. '/' .. claude.config.agents.work_dir
  local agent_dir = work_dir .. '/' .. claude.utils.agent_dirname(task)

  -- Add to gitignore first (before creating directory) to ensure it happens
  if claude.config.agents.auto_gitignore then
    claude.git.add_to_gitignore(claude.config.agents.work_dir .. '/')
  end

  -- Ensure work directory exists
  if not claude.utils.ensure_dir(work_dir) then
    vim.notify('Failed to create work directory', vim.log.levels.ERROR)
    return
  end

  -- Create agent directory
  if not claude.utils.ensure_dir(agent_dir) then
    vim.notify('Failed to create agent directory', vim.log.levels.ERROR)
    return
  end

  -- Handle fork options
  local success, result
  local base_info = ''

  if fork_from and fork_from.type == 'stash' then
    -- Create a stash first (including untracked files)
    vim.notify('Creating stash of current changes (including untracked files)...', vim.log.levels.INFO)
    local stash_cmd = 'git stash push -u -m "Agent fork: ' .. task:sub(1, 50) .. '"'
    local stash_result = claude.utils.exec(stash_cmd)

    if stash_result and stash_result:match 'Saved working directory' then
      -- Get the stash reference (it's the latest stash)
      local stash_ref = claude.utils.exec 'git rev-parse stash@{0}'
      if stash_ref then
        stash_ref = stash_ref:gsub('\n', '')
      end

      -- Create worktree from current branch
      local branch = claude.git.current_branch() or claude.git.default_branch()
      success, result = claude.git.create_worktree(agent_dir, branch)

      if success and stash_ref then
        -- Apply the stash in the new worktree using the SHA reference
        local apply_cmd = string.format('cd "%s" && git stash apply %s', agent_dir, stash_ref)
        local apply_result = claude.utils.exec(apply_cmd)

        if apply_result and not apply_result:match 'error:' then
          base_info = string.format('Forked from: %s (with stashed changes including untracked files)', branch)
          -- Pop the stash from the main repository since it was successfully applied
          claude.utils.exec 'git stash pop'
        else
          vim.notify('Warning: Could not apply stashed changes to worktree', vim.log.levels.WARN)
          base_info = string.format('Forked from: %s (stash apply failed)', branch)
        end
      end
    else
      vim.notify('No changes or untracked files to stash, using current branch', vim.log.levels.INFO)
      fork_from = { type = 'branch', branch = claude.git.current_branch() or claude.git.default_branch() }
    end
  end

  if not success and fork_from and fork_from.type == 'branch' then
    -- Create worktree from specified branch
    success, result = claude.git.create_worktree(agent_dir, fork_from.branch)
    base_info = string.format('Forked from: %s branch', fork_from.branch)
  elseif not success then
    -- Default behavior - use current branch
    local branch = claude.git.current_branch() or claude.git.default_branch()
    success, result = claude.git.create_worktree(agent_dir, branch)
    base_info = string.format('Forked from: %s branch', branch)
  end

  if not success then
    vim.notify('Failed to create worktree: ' .. tostring(result), vim.log.levels.ERROR)
    return
  end

  -- Create mission log with fork info
  local log_content =
    string.format('Agent Mission Log\n================\n\nTask: %s\nStarted: %s\nStatus: Active\n%s\n\n', task, os.date '%Y-%m-%d %H:%M:%S', base_info)
  claude.utils.write_file(agent_dir .. '/mission.log', log_content)

  -- Check agent limit
  local active_count = claude.registry.get_active_count()
  if active_count >= claude.config.agents.max_agents then
    vim.notify(
      string.format('Agent limit reached (%d/%d). Complete or kill existing agents first.', active_count, claude.config.agents.max_agents),
      vim.log.levels.ERROR
    )
    return
  end

  -- Create tmux window for agent
  local window_name = 'claude-' .. claude.utils.timestamp()
  local window_id = claude.tmux.create_agent_window(window_name, agent_dir)

  if window_id then
    -- Prepare fork info for registry
    local fork_info = {
      type = fork_from and fork_from.type or 'branch',
      branch = fork_from and fork_from.branch or (claude.git.current_branch() or claude.git.default_branch()),
      base_info = base_info,
    }

    -- Register agent with fork info
    local agent_id = claude.registry.register(task, agent_dir, window_id, window_name, fork_info)

    -- Update mission log with agent ID
    local log_content = claude.utils.read_file(agent_dir .. '/mission.log')
    log_content = log_content .. string.format('\nAgent ID: %s\n', agent_id)
    claude.utils.write_file(agent_dir .. '/mission.log', log_content)

    -- Create progress file for agent to update
    local progress_file = agent_dir .. '/progress.txt'
    claude.utils.write_file(progress_file, 'Starting...')

    -- Create agent-instructions.md with agent context
    local agent_instructions_path = agent_dir .. '/agent-instructions.md'

    -- Agent instructions should be fresh for each agent
    -- No need to check for existing content

    -- Build setup instructions section
    local setup_section = ''
    if setup_commands and #setup_commands > 0 then
      setup_section = '\n\n## IMPORTANT: Setup Instructions\n\nBefore you begin work on the task, you MUST run these setup commands in order:\n\n```bash\n'
      for _, cmd in ipairs(setup_commands) do
        setup_section = setup_section .. cmd .. '\n'
      end
      setup_section = setup_section .. '```\n\nIf any of these commands fail, stop and report the error. Do not proceed until all setup is complete.'
    end

    local agent_context = string.format(
      [[# Agent Context

## You are an autonomous agent

You are operating as an independent agent with a specific task to complete. This is your isolated workspace where you should work independently to accomplish your mission.%s

## Working Environment

- **Current directory**: `%s`
- **This is your isolated workspace** - all your work should be done here
- **Git worktree**: You're in a separate git worktree, so your changes won't affect the main repository

## Progress Reporting

To report your progress, update the file: `progress.txt`

Example:
```bash
echo 'Analyzing codebase structure...' > progress.txt
echo 'Found 3 areas that need refactoring' >> progress.txt
```

## Important Guidelines

1. **Work autonomously** - You should complete the task independently without asking for clarification
2. **Document your work** - Update progress.txt regularly with what you're doing
3. **Stay in this directory** - All work should be done in this agent workspace
4. **Complete the task** - Work until the task is fully completed or you encounter a blocking issue
5. **Commit your changes** - Once your task is completed follow the commit guidelines to commit your changes. The user will use this commit to cherry-pick onto their working branch

## Commit Guidelines

When your task is complete, please create a single, clean commit containing ONLY the relevant changes:

1. First, review all changes: `git status`
2. Stage ONLY files directly related to your task:
   ```bash
   git add src/specific-file.js
   git add src/another-file.js
   # Do NOT add: agent-instructions.md, CLAUDE.md, mission.log, progress.txt, test files, .env, etc.
   ```
3. Create a focused commit:
   ```bash
   git commit -m "feat: implement [specific feature description]"
   ```
4. Verify your commit contains only relevant changes: `git show --stat`

Remember: The goal is a clean commit that can be cherry-picked to the main branch.

## Additional Context

%s

## Mission Log

The file `mission.log` contains additional details about this agent's creation and configuration.
]],
      setup_section,
      agent_dir,
      base_info
    )

    -- Write agent instructions
    claude.utils.write_file(agent_instructions_path, agent_context)

    -- Add import to CLAUDE.md
    local claude_md_path = agent_dir .. '/CLAUDE.md'
    local claude_md_content = ''
    if claude.utils.file_exists(claude_md_path) then
      claude_md_content = claude.utils.read_file(claude_md_path) or ''
    end

    -- Add import if not already present
    local import_line = 'See @agent-instructions.md for more instructions'
    if not claude_md_content:match '@import agent%-instructions%.md' then
      if claude_md_content ~= '' then
        claude_md_content = claude_md_content .. '\n\n' .. import_line
      else
        claude_md_content = import_line
      end
      claude.utils.write_file(claude_md_path, claude_md_content)
    end

    -- In first pane (0) open Neovim
    claude.tmux.send_to_window(window_id, 'nvim .')

    -- Split right side 40% and open Claude
    local pane_claude = claude.tmux.split_window(window_id, 'h', 40)
    if pane_claude then
      -- First cd to the agent directory, then start Claude
      claude.tmux.send_to_pane(pane_claude, 'cd ' .. agent_dir)
      claude.tmux.send_to_pane(pane_claude, 'claude --dangerously-skip-permissions')

      -- Send the task as the initial prompt (formatted with sections)
      vim.wait(1000) -- Wait for Claude to start
      local formatted_task = M.format_task_sections(task)
      claude.tmux.send_text_to_pane(pane_claude, formatted_task)
    end

    vim.notify(
      string.format('Background agent started\nID: %s\nTask: %s\nWorkspace: %s\nWindow: %s\n%s', agent_id, task, agent_dir, window_name, base_info),
      vim.log.levels.INFO
    )
  else
    vim.notify('Failed to create agent window', vim.log.levels.ERROR)
  end
end

-- List all agents with interactive UI
function M.list_agents()
  -- Validate agents first
  claude.registry.validate_agents()

  local agents = claude.registry.get_project_agents()
  if vim.tbl_isempty(agents) then
    vim.notify('No agents found for this project', vim.log.levels.INFO)
    return
  end

  -- Sort agents by start time (newest first)
  table.sort(agents, function(a, b)
    return a.start_time > b.start_time
  end)

  -- Create interactive buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')

  -- Build display lines
  local lines = {}
  local agent_map = {} -- Map line numbers to agents

  table.insert(lines, ' Claude Agents')
  table.insert(lines, '')
  table.insert(lines, ' Keys: <Enter> switch · d diff · k kill · r refresh · q quit')
  table.insert(
    lines,
    '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  )
  table.insert(lines, '')

  local start_line = #lines + 1
  for i, agent in ipairs(agents) do
    local formatted = claude.registry.format_agent(agent)
    table.insert(lines, string.format(' %d. %s', i, formatted))
    agent_map[#lines] = agent

    -- Add work directory info
    local dir_info = '    ' .. (agent.work_dir:match '([^/]+)/?$' or agent.work_dir)
    table.insert(lines, dir_info)
    agent_map[#lines] = agent

    table.insert(lines, '')
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Create window
  local width = math.max(80, math.min(120, vim.o.columns - 10))
  local height = math.min(#lines + 2, vim.o.lines - 10)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Agent Manager ',
    title_pos = 'center',
  })

  -- Set initial cursor position
  vim.api.nvim_win_set_cursor(win, { start_line, 0 })

  -- Helper function to get agent under cursor
  local function get_current_agent()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return agent_map[row]
  end

  -- Keymaps
  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Enter - Switch to agent
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', '', {
    callback = function()
      local agent = get_current_agent()
      if agent then
        close_window()
        M.switch_agent(agent._registry_id)
      end
    end,
    silent = true,
  })

  -- d - Diff agent
  vim.api.nvim_buf_set_keymap(buf, 'n', 'd', '', {
    callback = function()
      local agent = get_current_agent()
      if agent then
        close_window()
        M.diff_agent(agent._registry_id)
      end
    end,
    silent = true,
  })

  -- k - Kill agent
  vim.api.nvim_buf_set_keymap(buf, 'n', 'k', '', {
    callback = function()
      local agent = get_current_agent()
      if agent and agent.status == 'active' then
        local msg = string.format('Kill agent "%s"?', agent.task:match '[^\n]*' or agent.task)
        local choice = vim.fn.confirm(msg, '&Yes\n&No', 2)
        if choice == 1 then
          M.kill_agent(agent._registry_id)
          close_window()
          -- Reopen the list to show updated state
          vim.defer_fn(function()
            M.list_agents()
          end, 100)
        end
      else
        vim.notify('Agent is not active', vim.log.levels.INFO)
      end
    end,
    silent = true,
  })

  -- r - Refresh
  vim.api.nvim_buf_set_keymap(buf, 'n', 'r', '', {
    callback = function()
      close_window()
      M.list_agents()
    end,
    silent = true,
  })

  -- Number keys for quick selection
  for i = 1, math.min(9, #agents) do
    vim.api.nvim_buf_set_keymap(buf, 'n', tostring(i), '', {
      callback = function()
        close_window()
        M.switch_agent(agents[i]._registry_id)
      end,
      silent = true,
    })
  end

  -- Close keymaps
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', { callback = close_window, silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', { callback = close_window, silent = true })

  -- Add highlighting
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder')
  vim.api.nvim_win_set_option(win, 'cursorline', true)
end

-- Kill an agent
function M.kill_agent(agent_id)
  if not agent_id or agent_id == '' then
    -- Show selection UI for agent killing
    M.show_kill_agent_ui()
    return
  end

  local agent = claude.registry.get(agent_id)
  if not agent then
    vim.notify('Agent not found: ' .. agent_id, vim.log.levels.ERROR)
    return
  end

  -- Kill tmux window
  if agent.window_id then
    local cmd = 'tmux kill-window -t ' .. agent.window_id
    claude.utils.exec(cmd)
  end

  -- Update registry
  claude.registry.update_status(agent_id, 'killed')

  vim.notify(string.format('Agent killed: %s (%s)', agent_id, agent.task), vim.log.levels.INFO)
end

-- Kill all active agents
function M.kill_all_agents()
  -- Validate agents first
  claude.registry.validate_agents()

  local agents = claude.registry.get_project_agents()
  local active_agents = {}

  for id, agent in pairs(agents) do
    if agent.status == 'active' then
      agent.id = id
      table.insert(active_agents, agent)
    end
  end

  if #active_agents == 0 then
    vim.notify('No active agents to kill', vim.log.levels.INFO)
    return
  end

  -- Show confirmation
  local agent_list = {}
  for _, agent in ipairs(active_agents) do
    table.insert(agent_list, '• ' .. (agent.task:match '[^\n]*' or agent.task))
  end

  local message = string.format('Kill %d active agent%s?\n\n%s', #active_agents, #active_agents > 1 and 's' or '', table.concat(agent_list, '\n'))

  local choice = vim.fn.confirm(message, '&Yes\n&No', 2)
  if choice == 1 then
    local killed_count = 0
    for _, agent in ipairs(active_agents) do
      -- Kill tmux window
      if agent.window_id then
        local cmd = 'tmux kill-window -t ' .. agent.window_id
        claude.utils.exec(cmd)
      end

      -- Update registry
      claude.registry.update_status(agent.id, 'killed')
      killed_count = killed_count + 1
    end

    vim.notify(string.format('Killed %d agent%s', killed_count, killed_count > 1 and 's' or ''), vim.log.levels.INFO)
  end
end

-- Show agent kill selection UI
function M.show_kill_agent_ui()
  -- Validate agents first
  claude.registry.validate_agents()

  local agents = claude.registry.get_project_agents()
  local active_agents = {}

  for id, agent in pairs(agents) do
    if agent.status == 'active' then
      agent.id = id
      table.insert(active_agents, agent)
    end
  end

  if #active_agents == 0 then
    vim.notify('No active agents to kill', vim.log.levels.INFO)
    return
  end

  -- Sort agents by start time
  table.sort(active_agents, function(a, b)
    return a.start_time > b.start_time
  end)

  -- Track selection state
  local selected = {}
  for i = 1, #active_agents do
    selected[i] = false
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  -- Create window
  local width = 80
  local height = math.min(#active_agents * 4 + 4, 25)
  local opts = {
    relative = 'editor',
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = 'minimal',
    border = 'rounded',
    title = ' Kill Claude Agents ',
    title_pos = 'center',
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Normal,FloatBorder:Comment')

  -- Function to update display
  local function update_display()
    local lines = { 'Kill Claude Agents (Space: toggle, Y: confirm kill, q: quit):', '' }

    for i, agent in ipairs(active_agents) do
      local icon = selected[i] and '●' or '○'
      local formatted = claude.registry.format_agent(agent)
      table.insert(lines, string.format('%s %s', icon, formatted))
      table.insert(lines, '    ID: ' .. agent.id)
      table.insert(lines, '    Window: ' .. (agent.window_name or 'unknown'))
      table.insert(lines, '')
    end

    -- Get current cursor position
    local cursor_line = 1
    if win and vim.api.nvim_win_is_valid(win) then
      cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    end

    -- Update buffer content
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)

    -- Restore cursor position
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { math.min(cursor_line, #lines), 0 })
    end
  end

  -- Initial display
  update_display()

  -- Set up keybindings
  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function get_agent_from_line(line)
    if line <= 2 then
      return nil
    end -- Header lines
    local agent_index = math.ceil((line - 2) / 4)
    return agent_index <= #active_agents and agent_index or nil
  end

  local function toggle_selection()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local agent_index = get_agent_from_line(line)

    if agent_index then
      selected[agent_index] = not selected[agent_index]
      update_display()
    end
  end

  local function confirm_kill()
    local selected_agents = {}
    for i, is_selected in ipairs(selected) do
      if is_selected then
        table.insert(selected_agents, active_agents[i])
      end
    end

    if #selected_agents == 0 then
      vim.notify('No agents selected', vim.log.levels.INFO)
      return
    end

    close_window()

    -- Confirm before killing
    local task_list = {}
    for _, agent in ipairs(selected_agents) do
      table.insert(task_list, '• ' .. agent.task:sub(1, 50))
    end

    vim.ui.select({ 'Yes', 'No' }, {
      prompt = string.format('Kill %d agent(s)?', #selected_agents),
      format_item = function(item)
        if item == 'Yes' then
          return 'Yes - Kill selected agents:\n' .. table.concat(task_list, '\n')
        else
          return 'No - Cancel'
        end
      end,
    }, function(choice)
      if choice == 'Yes' then
        for _, agent in ipairs(selected_agents) do
          M.kill_agent(agent.id)
        end
      end
    end)
  end

  -- Close on q or Esc
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '', {
    callback = close_window,
    silent = true,
    noremap = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '', {
    callback = close_window,
    silent = true,
    noremap = true,
  })

  -- Space to toggle selection
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Space>', '', {
    callback = toggle_selection,
    silent = true,
    noremap = true,
  })

  -- Y to confirm kill
  vim.api.nvim_buf_set_keymap(buf, 'n', 'Y', '', {
    callback = confirm_kill,
    silent = true,
    noremap = true,
  })
  vim.api.nvim_buf_set_keymap(buf, 'n', 'y', '', {
    callback = confirm_kill,
    silent = true,
    noremap = true,
  })
end

-- Clean up old agents
function M.clean_agents()
  -- Show cleanup options
  vim.ui.select(
    { 'Clean completed agents', 'Clean agents older than ' .. claude.config.agents.cleanup_days .. ' days', 'Clean ALL inactive agents', 'Cancel' },
    {
      prompt = 'Select cleanup option:',
    },
    function(choice)
      if not choice or choice == 'Cancel' then
        return
      end

      local removed = 0

      if choice == 'Clean completed agents' then
        removed = M.cleanup_completed_agents()
      elseif choice:match 'older than' then
        removed = claude.registry.cleanup(claude.config.agents.cleanup_days)
      elseif choice == 'Clean ALL inactive agents' then
        removed = M.cleanup_all_inactive_agents()
      end

      if removed > 0 then
        vim.notify(string.format('Cleaned up %d agent(s)', removed), vim.log.levels.INFO)
      else
        vim.notify('No agents to clean up', vim.log.levels.INFO)
      end
    end
  )
end

-- Clean up completed agents
function M.cleanup_completed_agents()
  local removed = 0
  local agents = claude.registry.get_project_agents()

  for _, agent in ipairs(agents) do
    if agent.status == 'completed' then
      -- Remove work directory
      if agent.work_dir and claude.utils.file_exists(agent.work_dir) then
        -- Remove git worktree properly
        claude.git.remove_worktree(agent.work_dir)
      end

      claude.registry.remove(agent.id)
      removed = removed + 1
    end
  end

  return removed
end

-- Clean up all inactive agents
function M.cleanup_all_inactive_agents()
  local removed = 0
  local agents = claude.registry.get_project_agents()

  for _, agent in ipairs(agents) do
    if agent.status ~= 'active' then
      -- Remove work directory
      if agent.work_dir and claude.utils.file_exists(agent.work_dir) then
        -- Remove git worktree properly
        claude.git.remove_worktree(agent.work_dir)
      end

      claude.registry.remove(agent.id)
      removed = removed + 1
    end
  end

  return removed
end

-- Clean orphaned agent directories
function M.clean_orphaned_directories()
  local work_dir = claude.utils.get_project_root() .. '/' .. claude.config.agents.work_dir

  if not claude.utils.file_exists(work_dir) then
    vim.notify('No agent work directory found', vim.log.levels.INFO)
    return
  end

  -- Get all directories in agent work dir
  local dirs = vim.fn.readdir(work_dir)
  local orphaned = {}

  -- Check each directory
  for _, dir in ipairs(dirs) do
    local dir_path = work_dir .. '/' .. dir
    local found = false

    -- Check if this directory is tracked by any agent
    local agents = claude.registry.get_project_agents()
    for _, agent in ipairs(agents) do
      if agent.work_dir == dir_path then
        found = true
        break
      end
    end

    if not found then
      table.insert(orphaned, dir_path)
    end
  end

  if #orphaned == 0 then
    vim.notify('No orphaned directories found', vim.log.levels.INFO)
    return
  end

  -- Confirm cleanup
  vim.ui.select({ 'Yes - Remove ' .. #orphaned .. ' orphaned directories', 'No - Cancel' }, {
    prompt = 'Found ' .. #orphaned .. ' orphaned agent directories. Clean them up?',
  }, function(choice)
    if choice and choice:match '^Yes' then
      local removed = 0
      for _, dir in ipairs(orphaned) do
        claude.git.remove_worktree(dir)
        removed = removed + 1
      end
      vim.notify(string.format('Removed %d orphaned directories', removed), vim.log.levels.INFO)
    end
  end)
end

-- Debug pane detection
function M.debug_panes()
  local utils = require 'nvim-claude.utils'

  -- Get all panes with details
  local cmd = "tmux list-panes -F '#{pane_id}:#{pane_pid}:#{pane_title}:#{pane_current_command}'"
  local result = utils.exec(cmd)

  local lines = { 'Claude Pane Debug Info:', '' }

  if result and result ~= '' then
    table.insert(lines, 'All panes:')
    for line in result:gmatch '[^\n]+' do
      local pane_id, pane_pid, pane_title, pane_cmd = line:match '^([^:]+):([^:]+):([^:]*):(.*)$'
      if pane_id and pane_pid then
        table.insert(lines, string.format('  %s: pid=%s, title="%s", cmd="%s"', pane_id, pane_pid, pane_title or '', pane_cmd or ''))
      end
    end
  else
    table.insert(lines, 'No panes found')
  end

  table.insert(lines, '')

  -- Show detected Claude pane
  local detected_pane = claude.tmux.find_claude_pane()
  if detected_pane then
    table.insert(lines, 'Detected Claude pane: ' .. detected_pane)
  else
    table.insert(lines, 'No Claude pane detected')
  end

  -- Display in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  local width = 80
  local height = math.min(#lines + 2, 25)
  local opts = {
    relative = 'editor',
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = 'minimal',
    border = 'rounded',
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Normal,FloatBorder:Comment')

  -- Close on q or Esc
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>', { silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>', { silent = true })
end

-- Switch to agent's worktree
function M.switch_agent(agent_id)
  -- Get agent from registry
  local agent = claude.registry.get(agent_id)
  if not agent then
    -- If no ID provided, show selection UI
    local agents = claude.registry.get_project_agents()
    if #agents == 0 then
      vim.notify('No agents found', vim.log.levels.INFO)
      return
    end

    -- Always show selection UI unless ID was provided
    M.show_agent_selection 'switch'
    return
  end

  -- Check if agent is still active
  if not claude.registry.check_window_exists(agent.window_id) then
    vim.notify('Agent window no longer exists', vim.log.levels.ERROR)
    return
  end

  -- Check if worktree still exists
  if not claude.utils.file_exists(agent.work_dir) then
    vim.notify(string.format('Agent work directory no longer exists: %s', agent.work_dir), vim.log.levels.ERROR)
    -- Try to check if it's a directory issue
    local parent_dir = vim.fn.fnamemodify(agent.work_dir, ':h')
    if claude.utils.file_exists(parent_dir) then
      vim.notify('Parent directory exists: ' .. parent_dir, vim.log.levels.INFO)
      -- List contents to debug
      local contents = vim.fn.readdir(parent_dir)
      if contents and #contents > 0 then
        vim.notify('Contents: ' .. table.concat(contents, ', '), vim.log.levels.INFO)
      end
    end
    return
  end

  -- Save current session state
  vim.cmd 'wall' -- Write all buffers

  -- Change to agent's worktree
  vim.cmd('cd ' .. agent.work_dir)

  -- Background agents keep hooks disabled - no inline diffs
  -- This keeps the workflow simple and predictable

  -- Clear all buffers and open new nvim in the worktree
  vim.cmd '%bdelete'
  vim.cmd 'edit .'

  -- Notify user
  vim.notify(
    string.format('Switched to agent worktree (no inline diffs)\nTask: %s\nWindow: %s\nUse :ClaudeDiffAgent to review changes', agent.task, agent.window_name),
    vim.log.levels.INFO
  )

  -- Also switch tmux to the agent's window
  local tmux_cmd = string.format('tmux select-window -t %s', agent.window_id)
  os.execute(tmux_cmd)
end

-- Show agent selection UI for different actions
function M.show_agent_selection(action)
  local agents = claude.registry.get_project_agents()

  if #agents == 0 then
    vim.notify('No active agents found', vim.log.levels.INFO)
    return
  end

  -- Create selection buffer
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { 'Select agent to ' .. action .. ':', '' }

  for i, agent in ipairs(agents) do
    local line = string.format('%d. %s', i, claude.registry.format_agent(agent))
    table.insert(lines, line)
  end

  table.insert(lines, '')
  table.insert(lines, 'Press number to select, q to quit')

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')

  -- Create floating window
  local width = math.max(60, math.min(100, vim.o.columns - 10))
  local height = math.min(#lines + 2, vim.o.lines - 10)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Agent Selection ',
    title_pos = 'center',
  })

  -- Set up keymaps for selection
  for i = 1, math.min(9, #agents) do
    vim.api.nvim_buf_set_keymap(buf, 'n', tostring(i), '', {
      silent = true,
      callback = function()
        vim.cmd 'close' -- Close selection window
        local selected_agent = agents[i]
        if selected_agent then
          if action == 'switch' then
            M.switch_agent(selected_agent.id)
          elseif action == 'diff' then
            M.diff_agent(selected_agent.id)
          end
        end
      end,
    })
  end

  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>', { silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>', { silent = true })
end

-- Rebuild agent registry from existing directories
function M.rebuild_agent_registry()
  local project_root = claude.utils.get_project_root()
  local work_dir = project_root .. '/' .. claude.config.agents.work_dir

  if not claude.utils.file_exists(work_dir) then
    vim.notify('No agent work directory found', vim.log.levels.INFO)
    return
  end

  -- Get all agent directories
  local agent_dirs = vim.fn.glob(work_dir .. '/agent-*', false, true)
  local rebuilt = 0

  for _, dir in ipairs(agent_dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      -- Extract agent name from directory
      local dir_name = vim.fn.fnamemodify(dir, ':t')

      -- Check if it's a git worktree (worktrees have a .git file, not directory)
      local is_worktree = vim.fn.filereadable(dir .. '/.git') == 1

      if is_worktree then
        -- Try to get window ID from tmux
        local window_name = 'agent-' .. dir_name:sub(7, 10) -- First 4 chars after 'agent-'
        local window_id = nil

        -- Try to find the tmux window
        local tmux_windows = claude.utils.exec "tmux list-windows -F '#{window_id} #{window_name}'"
        if tmux_windows then
          for line in tmux_windows:gmatch '[^\n]+' do
            local id, name = line:match '(@%d+) (.+)'
            if id and name and name == window_name then
              window_id = id
              break
            end
          end
        end

        -- Extract task from directory name (after timestamp)
        local task = dir_name:match 'agent%-[%d%-]+%-(.+)' or 'Unknown task'
        task = task:gsub('%-', ' ')

        -- Register the agent
        local id = claude.utils.timestamp() .. '-' .. math.random(1000, 9999)
        claude.registry.agents[id] = {
          id = id,
          task = task,
          work_dir = dir,
          window_id = window_id,
          window_name = window_name,
          start_time = vim.fn.getftime(dir), -- Use directory creation time
          status = window_id and claude.registry.check_window_exists(window_id) and 'active' or 'unknown',
          progress = 'Rebuilt from directory',
          last_update = os.time(),
          fork_info = { type = 'unknown', branch = claude.git.default_branch() },
        }

        rebuilt = rebuilt + 1
      end
    end
  end

  if rebuilt > 0 then
    claude.registry.save()
    vim.notify(string.format('Rebuilt registry with %d agents', rebuilt), vim.log.levels.INFO)
  else
    vim.notify('No agent worktrees found to rebuild', vim.log.levels.INFO)
  end
end

-- Review agent changes with diffview
function M.diff_agent(agent_id)
  -- Get agent from registry
  local agent = claude.registry.get(agent_id)
  if not agent then
    -- Check if we're currently in an agent worktree
    local current_dir = vim.fn.getcwd()
    local agents = claude.registry.get_project_agents()

    -- Try to find agent by work directory
    for _, a in ipairs(agents) do
      if a.work_dir == current_dir then
        agent = a
        break
      end
    end

    if not agent then
      -- If no ID provided and not in agent dir, show selection UI
      if #agents == 0 then
        vim.notify('No agents found', vim.log.levels.INFO)
        return
      elseif #agents == 1 then
        -- Auto-select the only agent
        agent = agents[1]
      else
        -- Show selection UI for multiple agents
        M.show_agent_selection 'diff'
        return
      end
    end
  end

  -- Check if worktree still exists
  if not claude.utils.file_exists(agent.work_dir) then
    vim.notify('Agent work directory no longer exists', vim.log.levels.ERROR)
    return
  end

  -- Get the base branch that the agent started from
  local base_branch = agent.fork_info and agent.fork_info.branch or (claude.git.current_branch() or claude.git.default_branch())

  -- Check if diffview is available
  local has_diffview = pcall(require, 'diffview')
  if not has_diffview then
    -- Fallback to fugitive
    vim.notify('Diffview not found, using fugitive', vim.log.levels.INFO)
    -- Save current directory and change to agent directory
    local original_cwd = vim.fn.getcwd()
    vim.cmd('cd ' .. agent.work_dir)
    vim.cmd('Git diff ' .. base_branch)
  else
    -- Save current directory to restore later
    local original_cwd = vim.fn.getcwd()

    -- Change to the agent's worktree directory
    vim.cmd('cd ' .. agent.work_dir)

    -- Set up autocmd to restore directory when diffview closes
    local restore_dir_group = vim.api.nvim_create_augroup('ClaudeRestoreDir', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      pattern = 'DiffviewViewClosed',
      group = restore_dir_group,
      once = true,
      callback = function()
        vim.cmd('cd ' .. original_cwd)
      end,
    })

    -- Also restore on BufWinLeave as a fallback
    vim.api.nvim_create_autocmd('BufWinLeave', {
      pattern = 'diffview://*',
      group = restore_dir_group,
      once = true,
      callback = function()
        -- Small delay to ensure diffview cleanup is complete
        vim.defer_fn(function()
          if vim.fn.getcwd() ~= original_cwd then
            vim.cmd('cd ' .. original_cwd)
          end
        end, 100)
      end,
    })

    -- Now diffview will work in the context of the worktree
    -- First check if there are uncommitted changes
    local git_status = claude.git.status(agent.work_dir)
    local has_uncommitted = #git_status > 0

    if has_uncommitted then
      -- Show working directory changes (including uncommitted files)
      vim.cmd 'DiffviewOpen'
      vim.notify(
        string.format(
          'Showing uncommitted changes in agent worktree\nTask: %s\nWorktree: %s\n\nNote: Agent has uncommitted changes. To see branch diff, commit the changes first.',
          agent.task:match '[^\n]*' or agent.task,
          agent.work_dir
        ),
        vim.log.levels.INFO
      )
    else
      -- Use triple-dot notation to compare against the merge-base
      local cmd = string.format(':DiffviewOpen %s...HEAD --imply-local', base_branch)
      vim.cmd(cmd)
      vim.notify(
        string.format(
          'Reviewing agent changes\nTask: %s\nComparing against: %s\nWorktree: %s\nOriginal dir: %s',
          agent.task:match '[^\n]*' or agent.task,
          base_branch,
          agent.work_dir,
          original_cwd
        ),
        vim.log.levels.INFO
      )
    end
  end
end

-- Checkpoint commands

-- Open checkpoint browser
function M.open_checkpoints()
  local checkpoint = require 'nvim-claude.checkpoint'
  local checkpoints = checkpoint.list_checkpoints()

  if #checkpoints == 0 then
    vim.notify('No checkpoints found', vim.log.levels.INFO)
    return
  end

  -- TODO: Implement telescope picker
  -- For now, use basic vim.ui.select
  local items = {}
  for _, cp in ipairs(checkpoints) do
    local date = os.date('%Y-%m-%d %H:%M:%S', cp.timestamp)
    table.insert(items, string.format('%s | %s', date, cp.prompt))
  end

  vim.ui.select(items, {
    prompt = 'Select checkpoint to restore:',
  }, function(choice, idx)
    if choice and idx then
      checkpoint.restore_checkpoint(checkpoints[idx].id)
    end
  end)
end

-- Create checkpoint manually
function M.create_checkpoint(message)
  local checkpoint = require 'nvim-claude.checkpoint'
  local checkpoint_id = checkpoint.create_checkpoint(message or 'Manual checkpoint')

  if checkpoint_id then
    vim.notify('Created checkpoint: ' .. checkpoint_id, vim.log.levels.INFO)
  else
    vim.notify('Failed to create checkpoint', vim.log.levels.ERROR)
  end
end

-- Restore specific checkpoint
function M.restore_checkpoint(checkpoint_id)
  local checkpoint = require 'nvim-claude.checkpoint'
  if checkpoint.restore_checkpoint(checkpoint_id) then
    vim.notify('Restored checkpoint: ' .. checkpoint_id, vim.log.levels.INFO)
  else
    vim.notify('Failed to restore checkpoint', vim.log.levels.ERROR)
  end
end

-- Show checkpoint status
function M.checkpoint_status()
  local checkpoint = require 'nvim-claude.checkpoint'

  if checkpoint.is_preview_mode() then
    local state = checkpoint.load_state()
    vim.notify(
      string.format(
        'Preview mode active\nCheckpoint: %s\nOriginal ref: %s\nStash: %s',
        state.preview_checkpoint,
        state.original_ref,
        state.preview_stash or 'none'
      ),
      vim.log.levels.INFO
    )
  else
    local checkpoints = checkpoint.list_checkpoints()
    vim.notify(string.format('Working mode\nTotal checkpoints: %d', #checkpoints), vim.log.levels.INFO)
  end
end

-- Accept current checkpoint
function M.accept_checkpoint()
  local checkpoint = require 'nvim-claude.checkpoint'
  if checkpoint.accept_checkpoint() then
    vim.notify('Checkpoint accepted', vim.log.levels.INFO)
  else
    vim.notify('Not in preview mode', vim.log.levels.WARN)
  end
end

-- Return from checkpoint
function M.return_from_checkpoint()
  local checkpoint = require 'nvim-claude.checkpoint'
  if checkpoint.exit_preview_mode() then
    vim.notify('Returned to original state', vim.log.levels.INFO)
  else
    vim.notify('Not in preview mode', vim.log.levels.WARN)
  end
end

return M
