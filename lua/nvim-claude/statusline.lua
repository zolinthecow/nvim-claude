-- Statusline components for nvim-claude
local M = {}

-- Get active agent count and summary
function M.get_agent_status()
  local ba = require('nvim-claude.background_agent')
  return ba.get_status() or ''
end

-- Lualine component
function M.lualine_component()
  return {
    M.get_agent_status,
    cond = function()
      -- Only show if there are active agents
      local status = M.get_agent_status()
      return status ~= ''
    end,
    on_click = function()
      -- Open agent list on click
      vim.cmd('ClaudeAgents')
    end,
  }
end

-- Simple string function for custom statuslines
function M.statusline()
  local status = M.get_agent_status()
  if status ~= '' then
    return ' ' .. status .. ' '
  end
  return ''
end

return M
