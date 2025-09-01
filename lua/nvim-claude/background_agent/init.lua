-- Background agent façade: explicit public API

local M = {}

local registry = require 'nvim-claude.background_agent.registry'
local status = require 'nvim-claude.background_agent.status'
local runner = require 'nvim-claude.background_agent.runner'
local creator = require 'nvim-claude.background_agent.create'

-- Public status API (used by statusline and others)
function M.get_status()
  return status.get_status()
end

-- Public registry helpers (expose common ops explicitly as needed)
function M.registry_setup(cfg)
  return registry.setup(cfg)
end
function M.registry_validate()
  return registry.validate_agents()
end
function M.registry_agents()
  return registry.get_project_agents()
end
function M.registry_active_count()
  return registry.get_active_count()
end
function M.registry_format(agent)
  return registry.format_agent(agent)
end

-- Public diff helpers
function M.open_diff(agent)
  return require('nvim-claude.background_agent.diff').open(agent)
end
function M.open_diff_by_id(id)
  return require('nvim-claude.background_agent.diff').open_by_id(id)
end

-- Public UI: agent list picker
function M.show_agent_list()
  return require('nvim-claude.background_agent.ui.list').show()
end

-- Public UI: kill selection
function M.show_kill_ui()
  return require('nvim-claude.background_agent.ui.kill').show()
end

-- Public runner helpers
function M.switch_agent(id)
  return runner.switch_agent_by_id(id)
end
function M.kill_agent(id)
  return runner.kill_agent_by_id(id)
end

-- Kill all active agents with confirmation
function M.kill_all()
  M.registry_validate()
  local agents = M.registry_agents()
  local active = {}
  for _, a in ipairs(agents) do if a.status == 'active' then table.insert(active, a) end end
  if #active == 0 then
    vim.notify('No active agents to kill', vim.log.levels.INFO)
    return 0
  end
  local lines = {}
  for _, a in ipairs(active) do table.insert(lines, '• ' .. (a.task:match('[^\n]*') or a.task)) end
  local message = string.format('Kill %d active agent%s?\n\n%s', #active, #active > 1 and 's' or '', table.concat(lines, '\n'))
  local choice = vim.fn.confirm(message, '&Yes\n&No', 2)
  if choice ~= 1 then return 0 end
  local killed = 0
  for _, a in ipairs(active) do
    if runner.kill_agent_by_id(a.id or a._registry_id) then killed = killed + 1 end
  end
  vim.notify(string.format('Killed %d agent%s', killed, killed ~= 1 and 's' or ''), vim.log.levels.INFO)
  return killed
end

-- Interactive create flow (UI)
function M.start_create_flow()
  return require('nvim-claude.background_agent.ui.create').start()
end

-- Non-interactive create
function M.create_agent(task, fork_from, setup_commands)
  return creator.create(task, fork_from, setup_commands)
end

return M
