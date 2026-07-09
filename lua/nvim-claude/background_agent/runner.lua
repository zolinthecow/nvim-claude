-- Runner helpers: switch/kill agent tmux windows (internal)

local M = {}

local utils = require('nvim-claude.utils')
local tmux = utils.tmux
local registry = require('nvim-claude.background_agent.registry')

local function kill_window(window_id)
  if not window_id or window_id == '' then return false end
  local _, err = utils.exec('tmux kill-window -t ' .. vim.fn.shellescape(window_id))
  return err == nil
end

function M.switch_agent_by_id(agent_id)
  local project_root = utils.get_project_root()
  local agent = registry.get(agent_id, project_root)
  if not agent then
    vim.notify('Agent not found: ' .. tostring(agent_id), vim.log.levels.ERROR)
    return false
  end
  if not tmux.is_inside_tmux() then
    vim.notify('Not inside tmux; cannot switch windows', vim.log.levels.ERROR)
    return false
  end
  if agent.window_id and registry.check_window_exists(agent.window_id) then
    tmux.switch_to_window(agent.window_id)
    return true
  else
    vim.notify('Agent window no longer exists', vim.log.levels.WARN)
    -- Mark completed if missing window
    registry.update_status(agent_id, 'completed', project_root)
    return false
  end
end

function M.kill_agent_by_id(agent_id)
  local project_root = utils.get_project_root()
  local agent = registry.get(agent_id, project_root)
  if not agent then
    vim.notify('Agent not found: ' .. tostring(agent_id), vim.log.levels.ERROR)
    return false
  end
  if agent.window_id and registry.check_window_exists(agent.window_id) then
    if not kill_window(agent.window_id) then
      vim.notify('Failed to kill agent window', vim.log.levels.ERROR)
      return false
    end
  end
  if not registry.update_status(agent_id, 'killed', project_root) then
    vim.notify('Agent window closed, but status could not be saved', vim.log.levels.ERROR)
    return false
  end
  vim.notify(string.format('Agent killed: %s', agent.task:match('[^\n]*') or agent.task), vim.log.levels.INFO)
  return true
end

return M
