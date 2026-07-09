-- Create background agents (non-interactive)

local M = {}

local utils = require('nvim-claude.utils')
local git = utils.git
local tmux = utils.tmux
local registry = require('nvim-claude.background_agent.registry')
local worktree = require('nvim-claude.background_agent.worktree')
local config = require('nvim-claude.background_agent.config')
local logger = require('nvim-claude.logger')

local function rollback(project_root, agent_dir, window_id)
  if window_id then
    utils.exec('tmux kill-window -t ' .. vim.fn.shellescape(window_id))
  end
  if agent_dir and utils.file_exists(agent_dir) then
    local ok, err = worktree.remove(agent_dir, project_root)
    if not ok then
      logger.error('background_agent.create', 'Failed to roll back worktree', {
        worktree = agent_dir,
        error = err,
      })
    end
  end
  local work_dir = agent_dir and vim.fn.fnamemodify(agent_dir, ':h') or nil
  if work_dir and vim.fn.isdirectory(work_dir) == 1 and #vim.fn.readdir(work_dir) == 0 then
    vim.fn.delete(work_dir, 'd')
  end
end

local function format_task_sections(task_string)
  local formatted = {}
  local task_match = task_string:match '## Task:%s*\n(.-)\n%s*## Goals:'
  local goals_match = task_string:match '## Goals:%s*\n(.-)\n%s*## Notes:'
  local notes_match = task_string:match '## Notes:%s*\n(.*)$'

  if task_match then
    local cleaned = task_match:gsub('^%s*', ''):gsub('%s*$', '')
    if cleaned ~= '' and cleaned ~= '-' then
      table.insert(formatted, '# Task')
      table.insert(formatted, cleaned)
    end
  end
  if goals_match then
    local cleaned = goals_match:gsub('^%s*', ''):gsub('%s*$', '')
    if cleaned ~= '' and cleaned ~= '-' and not cleaned:match '^%-%s*$' then
      if #formatted > 0 then table.insert(formatted, '') end
      table.insert(formatted, '# Goals')
      table.insert(formatted, cleaned)
    end
  end
  if notes_match then
    local cleaned = notes_match:gsub('^%s*', ''):gsub('%s*$', '')
    if cleaned ~= '' and cleaned ~= '-' and not cleaned:match '^%-%s*$' then
      if #formatted > 0 then table.insert(formatted, '') end
      table.insert(formatted, '# Notes')
      table.insert(formatted, cleaned)
    end
  end
  if #formatted == 0 then
    local cleaned = task_string:gsub('^%s+', ''):gsub('%s+$', '')
    if cleaned ~= '' then
      table.insert(formatted, '# Task')
      table.insert(formatted, cleaned)
    end
  end
  return table.concat(formatted, '\n')
end

-- Create the agent worktree, tmux window, files, and registry entry
function M.create(task, fork_from, setup_commands)
  if not tmux.validate() then return false, 'Not inside tmux' end
  if type(task) ~= 'string' or vim.trim(task) == '' then return false, 'Task is required' end

  local project_root = utils.get_project_root()
  if not project_root then return false, 'No project root found' end
  local cfg = config.get()
  local work_dir = project_root .. '/' .. (cfg.work_dir or '.agent-work')
  local agent_dir = work_dir .. '/' .. utils.agent_dirname(task)

  registry.validate_agents(project_root)
  local active_count = registry.get_active_count(project_root)
  if cfg.max_agents and active_count >= cfg.max_agents then
    return false, string.format('Agent limit reached (%d/%d)', active_count, cfg.max_agents)
  end

  if not utils.ensure_dir(work_dir) then
    return false, 'Failed to create work directory'
  end

  local ok, info = worktree.create(agent_dir, fork_from, task, project_root)
  if not ok then
    rollback(project_root, agent_dir)
    return false, info
  end

  local base_info = info.base_info or ''

  -- Mission log
  local log_content = string.format('Agent Mission Log\n================\n\nTask: %s\nStarted: %s\nStatus: Active\n%s\n\n', task, os.date '%Y-%m-%d %H:%M:%S', base_info)
  if not utils.write_file(agent_dir .. '/mission.log', log_content) then
    rollback(project_root, agent_dir)
    return false, 'Failed to write agent mission log'
  end

  -- progress.txt
  if not utils.write_file(agent_dir .. '/progress.txt', 'Starting...') then
    rollback(project_root, agent_dir)
    return false, 'Failed to write agent progress file'
  end

  -- agent-instructions.md with optional setup section
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
5. **Commit your changes** - Once your task is completed follow the commit guidelines to commit your changes. The user will use this commit to cherry-pick onto the base branch
6. **Notify the user** - Notify the user that you have created the commit and tell them how they can cherry-pick it onto the base branch.

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

5. Notify the user that the commit has been created. Tell them the commit ID and give them a simple command that they can use to cherry-pick it onto the base branch.

## Additional Context

%s

## Mission Log

The file `mission.log` contains additional details about this agent's creation and configuration.
]],
    setup_section,
    agent_dir,
    base_info
  )

  if not utils.write_file(agent_dir .. '/agent-instructions.md', agent_context) then
    rollback(project_root, agent_dir)
    return false, 'Failed to write agent instructions'
  end

  -- Provider-specific context injection (e.g., CLAUDE.md import)
  local agent_provider = require('nvim-claude.agent_provider')
  logger.debug('background_agent.create', 'calling provider.append_to_context', { dir = agent_dir })
  local ok_append, append_result = pcall(agent_provider.background.append_to_context, agent_dir)
  local err_append = ok_append and nil or append_result
  logger.debug('background_agent.create', 'provider.append_to_context returned', { ok = ok_append, err = err_append })
  if not ok_append or append_result == false then
    rollback(project_root, agent_dir)
    return false, 'Failed to prepare provider context: ' .. tostring(err_append or 'provider rejected context')
  end

  local window_name = agent_provider.background.generate_window_name()
  local window_id = tmux.create_agent_window(window_name, agent_dir)
  if not window_id then
    rollback(project_root, agent_dir)
    return false, 'Failed to create agent tmux window'
  end

  -- Launch in tmux panes
  if not tmux.send_to_window(window_id, 'nvim .') then
    rollback(project_root, agent_dir, window_id)
    return false, 'Failed to launch Neovim in agent window'
  end
  local formatted_task = format_task_sections(task)
  local pane_id = agent_provider.background.launch_agent_pane(window_id, agent_dir, formatted_task)
  if not pane_id then
    rollback(project_root, agent_dir, window_id)
    return false, 'Failed to launch agent pane'
  end

  local fallback_fork = {
    type = fork_from and fork_from.type or 'branch',
    branch = fork_from and fork_from.branch or (git.current_branch(project_root) or git.default_branch(project_root)),
  }
  local agent_id, register_err = registry.register(
    task,
    agent_dir,
    window_id,
    window_name,
    info.fork_info or fallback_fork,
    project_root,
    cfg.max_agents
  )
  if not agent_id then
    rollback(project_root, agent_dir, window_id)
    return false, register_err or 'Failed to register agent'
  end

  local new_log = (utils.read_file(agent_dir .. '/mission.log') or '') .. string.format('\nAgent ID: %s\n', agent_id)
  if not utils.write_file(agent_dir .. '/mission.log', new_log) then
    logger.warn('background_agent.create', 'Failed to append agent id to mission log', { agent_id = agent_id })
  end
  if cfg.auto_gitignore and not git.add_to_gitignore((cfg.work_dir or '.agent-work') .. '/', project_root) then
    logger.warn('background_agent.create', 'Failed to update .gitignore', { project_root = project_root })
  end

  vim.notify(string.format('Background agent started\nID: %s\nTask: %s\nWorkspace: %s\nWindow: %s\n%s', agent_id, task, agent_dir, window_name, base_info), vim.log.levels.INFO)
  return true, agent_id
end

return M
