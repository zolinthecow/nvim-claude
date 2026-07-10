-- Background agent status helpers

local M = {}

local registry = require('nvim-claude.background_agent.registry')
local utils = require('nvim-claude.utils')
local last_validation = {}

-- Compose a concise status string for statusline integrations
function M.get_status()
  local project_root = utils.get_project_root()
  local now = vim.loop.hrtime()
  local previous = last_validation[project_root] or 0
  if now - previous >= 1e9 then
    registry.validate_agents(project_root)
    last_validation[project_root] = now
  end
  local agents = registry.get_project_agents(project_root)

  local active_count = 0
  local latest_progress = nil
  local latest_task = nil
  local latest_update = 0

  for _, agent in ipairs(agents) do
    if agent.status == 'active' then
      active_count = active_count + 1
      local lu = agent.last_update or 0
      if lu >= latest_update then
        latest_update = lu
        latest_progress = agent.progress
        latest_task = agent.task
      end
    end
  end

  if active_count == 0 then
    return ''
  elseif active_count == 1 and latest_progress and latest_task then
    local task_short = latest_task
    if #task_short > 20 then
      task_short = task_short:sub(1, 17) .. '...'
    end
    return string.format('🤖 %s: %s', task_short, latest_progress)
  else
    return string.format('🤖 %d agents', active_count)
  end
end

return M
