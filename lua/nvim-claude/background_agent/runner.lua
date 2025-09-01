-- Runner helpers: switch/kill agent tmux windows (internal)

local M = {}

local utils = require('nvim-claude.utils')
local tmux = require('nvim-claude.tmux')
local registry = require('nvim-claude.background_agent.registry')

local function kill_window(window_id)
  if not window_id or window_id == '' then return false end
  utils.exec('tmux kill-window -t ' .. window_id)
  return true
end

function M.switch_agent_by_id(agent_id)
  local agent = registry.get(agent_id)
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
    registry.update_status(agent_id, 'completed')
    return false
  end
end

function M.kill_agent_by_id(agent_id)
  local agent = registry.get(agent_id)
  if not agent then
    vim.notify('Agent not found: ' .. tostring(agent_id), vim.log.levels.ERROR)
    return false
  end
  if agent.window_id and registry.check_window_exists(agent.window_id) then
    kill_window(agent.window_id)
  end
  registry.update_status(agent_id, 'killed')
  vim.notify(string.format('Agent killed: %s', agent.task:match('[^\n]*') or agent.task), vim.log.levels.INFO)
  return true
end

return M

