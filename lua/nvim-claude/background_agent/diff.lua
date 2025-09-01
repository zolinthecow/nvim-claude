-- Diff helpers for background agents

local M = {}

local utils = require('nvim-claude.utils')
local git = require('nvim-claude.git')
local registry = require('nvim-claude.background_agent.registry')

local function base_branch_for(agent)
  return (agent.fork_info and agent.fork_info.branch) or (git.current_branch() or git.default_branch())
end

local function restore_cwd_on_close(original_cwd)
  local restore_dir_group = vim.api.nvim_create_augroup('ClaudeRestoreDir', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    pattern = 'DiffviewViewClosed',
    group = restore_dir_group,
    once = true,
    callback = function()
      vim.cmd('cd ' .. original_cwd)
    end,
  })
  vim.api.nvim_create_autocmd('BufWinLeave', {
    pattern = 'diffview://*',
    group = restore_dir_group,
    once = true,
    callback = function()
      vim.defer_fn(function()
        if vim.fn.getcwd() ~= original_cwd then
          vim.cmd('cd ' .. original_cwd)
        end
      end, 100)
    end,
  })
end

local function open_in_main(agent)
  if not utils.file_exists(agent.work_dir) then
    vim.notify('Agent work directory no longer exists', vim.log.levels.ERROR)
    return false
  end

  local original_cwd = vim.fn.getcwd()
  vim.cmd('cd ' .. agent.work_dir)

  local has_diffview = pcall(require, 'diffview')
  if has_diffview then
    restore_cwd_on_close(original_cwd)
    local st = git.status(agent.work_dir)
    local has_uncommitted = #st > 0
    if has_uncommitted then
      vim.cmd('DiffviewOpen')
      vim.notify(
        string.format(
          'Showing uncommitted changes in agent worktree\nTask: %s\nWorktree: %s\n\nNote: Commit changes to compare with base branch.',
          agent.task:match('[^\n]*') or agent.task,
          agent.work_dir
        ),
        vim.log.levels.INFO
      )
    else
      local base = base_branch_for(agent)
      vim.cmd(string.format('DiffviewOpen %s...HEAD --imply-local', base))
      vim.notify(
        string.format(
          'Reviewing agent changes\nTask: %s\nComparing against: %s\nWorktree: %s',
          agent.task:match('[^\n]*') or agent.task,
          base,
          agent.work_dir
        ),
        vim.log.levels.INFO
      )
    end
    return true
  else
    -- Fallback to fugitive
    local base = base_branch_for(agent)
    vim.cmd('Git diff ' .. base)
    return true
  end
end

function M.open(agent)
  return open_in_main(agent)
end

function M.open_by_id(agent_id)
  local agent = registry.get(agent_id)
  if not agent then return false end
  return M.open(agent)
end

return M

