-- Maintenance helpers for background agents: rebuild, cleanup, orphans

local M = {}

local utils = require('nvim-claude.utils')
local git = utils.git
local registry = require('nvim-claude.background_agent.registry')
local config = require('nvim-claude.background_agent.config')

-- Rebuild agent registry by scanning work_dir for worktrees
function M.rebuild_registry()
  local project_root = utils.get_project_root()
  if not project_root then
    vim.notify('No project root found', vim.log.levels.ERROR)
    return 0
  end

  local cfg = config.get()
  local work_dir = project_root .. '/' .. (cfg.work_dir or '.agent-work')
  if not utils.file_exists(work_dir) then
    vim.notify('No agent work directory found', vim.log.levels.INFO)
    return 0
  end

  local agent_dirs = vim.fn.glob(work_dir .. '/agent-*', false, true)
  local rebuilt = 0
  local rebuilt_agents = {}

  for _, dir in ipairs(agent_dirs) do
    if vim.fn.isdirectory(dir) == 1 and vim.fn.filereadable(dir .. '/.git') == 1 then
      local dir_name = vim.fn.fnamemodify(dir, ':t')
      local window_name = 'agent-' .. dir_name:sub(7, 10)

      -- Detect tmux window id for the presumed name
      local window_id = nil
      local tmux_windows = utils.exec("tmux list-windows -F '#{window_id} #{window_name}'")
      if tmux_windows then
        for line in tmux_windows:gmatch('[^\n]+') do
          local id, name = line:match('(@%d+) (.+)')
          if id and name and name == window_name then
            window_id = id
            break
          end
        end
      end

      local task = dir_name:match('agent%-[%d%-]+%-(.+)') or 'Unknown task'
      task = task:gsub('%-', ' ')

      local id = dir_name
      rebuilt_agents[id] = {
        id = id,
        task = task,
        work_dir = dir,
        window_id = window_id,
        window_name = window_name,
        project_root = project_root,
        start_time = os.time(),
        last_update = os.time(),
        status = window_id and 'active' or 'completed',
        progress = utils.read_file(dir .. '/progress.txt') or '',
        fork_info = { type = 'unknown', branch = git.default_branch(project_root) },
      }
      rebuilt = rebuilt + 1
    end
  end

  local saved = registry.save(project_root, rebuilt_agents)
  if not saved then
    vim.notify('Failed to save rebuilt agent registry', vim.log.levels.ERROR)
    return 0
  end
  if rebuilt > 0 then
    vim.notify(string.format('Rebuilt registry with %d agents', rebuilt), vim.log.levels.INFO)
  else
    vim.notify('No agent worktrees found to rebuild', vim.log.levels.INFO)
  end
  return rebuilt
end

-- Remove directories in work_dir that are not tracked by registry
function M.clean_orphans()
  local project_root = utils.get_project_root()
  if not project_root then return 0 end
  local cfg = config.get()
  local work_dir = project_root .. '/' .. (cfg.work_dir or '.agent-work')
  if not utils.file_exists(work_dir) then
    vim.notify('No agent work directory found', vim.log.levels.INFO)
    return 0
  end

  local dirs = vim.fn.readdir(work_dir)
  local orphans = {}
  local agents = registry.get_project_agents(project_root)
  local tracked = {}
  for _, a in ipairs(agents) do tracked[a.work_dir] = true end
  for _, d in ipairs(dirs) do
    local path = work_dir .. '/' .. d
    if vim.fn.isdirectory(path) == 1 and not tracked[path] then
      table.insert(orphans, path)
    end
  end
  if #orphans == 0 then
    vim.notify('No orphaned directories found', vim.log.levels.INFO)
    return 0
  end
  local removed = 0
  for _, dir in ipairs(orphans) do
    local ok = git.remove_worktree(dir, project_root)
    if ok then removed = removed + 1 end
  end
  vim.notify(string.format('Removed %d orphaned directories', removed), vim.log.levels.INFO)
  return removed
end

function M.cleanup_completed()
  local project_root = utils.get_project_root()
  local removed = 0
  for _, agent in ipairs(registry.get_project_agents(project_root)) do
    if agent.status == 'completed' then
      local worktree_removed = true
      if agent.work_dir and utils.file_exists(agent.work_dir) then
        worktree_removed = git.remove_worktree(agent.work_dir, project_root)
      end
      if worktree_removed and registry.remove(agent.id or agent._registry_id, project_root) then
        removed = removed + 1
      end
    end
  end
  return removed
end

function M.cleanup_all_inactive()
  local project_root = utils.get_project_root()
  local removed = 0
  for _, agent in ipairs(registry.get_project_agents(project_root)) do
    if agent.status ~= 'active' then
      local worktree_removed = true
      if agent.work_dir and utils.file_exists(agent.work_dir) then
        worktree_removed = git.remove_worktree(agent.work_dir, project_root)
      end
      if worktree_removed and registry.remove(agent.id or agent._registry_id, project_root) then
        removed = removed + 1
      end
    end
  end
  return removed
end

function M.cleanup_older_than(days)
  return registry.cleanup(days, utils.get_project_root())
end

return M
