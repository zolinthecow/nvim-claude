-- Create background agents (non-interactive)

local M = {}

local nvc = require('nvim-claude')
local utils = require('nvim-claude.utils')
local git = utils.git
local tmux = utils.tmux
local registry = require('nvim-claude.background_agent.registry')
local worktree = require('nvim-claude.background_agent.worktree')

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

  local project_root = utils.get_project_root()
  local cfg = nvc.config and nvc.config.agents or { work_dir = '.agent-work', auto_gitignore = true, max_agents = 5 }
  local work_dir = project_root .. '/' .. (cfg.work_dir or '.agent-work')
  local agent_dir = work_dir .. '/' .. utils.agent_dirname(task)

  if cfg.auto_gitignore then
    git.add_to_gitignore((cfg.work_dir or '.agent-work') .. '/')
  end

  if not utils.ensure_dir(work_dir) then
    return false, 'Failed to create work directory'
  end
  if not utils.ensure_dir(agent_dir) then
    return false, 'Failed to create agent directory'
  end

  local ok, info = worktree.create(agent_dir, fork_from, task)
  if not ok then
    return false, info
  end

  local base_info = info.base_info or ''

  -- Mission log
  local log_content = string.format('Agent Mission Log\n================\n\nTask: %s\nStarted: %s\nStatus: Active\n%s\n\n', task, os.date '%Y-%m-%d %H:%M:%S', base_info)
  utils.write_file(agent_dir .. '/mission.log', log_content)

  -- Agent limit
  local active_count = registry.get_active_count()
  if cfg.max_agents and active_count >= cfg.max_agents then
    return false, string.format('Agent limit reached (%d/%d)', active_count, cfg.max_agents)
  end

  -- tmux window
  local window_name = 'claude-' .. utils.timestamp()
  local window_id = tmux.create_agent_window(window_name, agent_dir)
  if not window_id then
    return false, 'Failed to create agent tmux window'
  end

  local agent_id = registry.register(task, agent_dir, window_id, window_name, info.fork_info or { type = fork_from and fork_from.type or 'branch', branch = fork_from and fork_from.branch or (git.current_branch() or git.default_branch()) })

  -- Update mission log with Agent ID
  local new_log = (utils.read_file(agent_dir .. '/mission.log') or '') .. string.format('\nAgent ID: %s\n', agent_id)
  utils.write_file(agent_dir .. '/mission.log', new_log)

  -- progress.txt
  utils.write_file(agent_dir .. '/progress.txt', 'Starting...')

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

  utils.write_file(agent_dir .. '/agent-instructions.md', agent_context)

  -- CLAUDE.md import
  local claude_md_path = agent_dir .. '/CLAUDE.md'
  local claude_md_content = utils.file_exists(claude_md_path) and (utils.read_file(claude_md_path) or '') or ''
  local import_line = 'See @agent-instructions.md for more instructions'
  if not claude_md_content:match '@import agent%-instructions%.md' then
    if claude_md_content ~= '' then
      claude_md_content = claude_md_content .. '\n\n' .. import_line
    else
      claude_md_content = import_line
    end
    utils.write_file(claude_md_path, claude_md_content)
  end

  -- Launch in tmux panes
  tmux.send_to_window(window_id, 'nvim .')
  local formatted_task = format_task_sections(task)
  local agent_provider = require('nvim-claude.agent_provider')
  agent_provider.background.launch_agent_pane(window_id, agent_dir, formatted_task)

  vim.notify(string.format('Background agent started\nID: %s\nTask: %s\nWorkspace: %s\nWindow: %s\n%s', agent_id, task, agent_dir, window_name, base_info), vim.log.levels.INFO)
  return true, agent_id
end

return M
