-- Aggregated command registration (new structure)
-- Each register_* function defines user commands for a feature area.
-- Call register_all() from init once migration is complete.

local M = {}

-- Background agent commands are registered by feature module

-- Checkpoint commands
function M.register_checkpoints() end

function M.register_all(claude)
  -- Feature-scoped command registrars
  pcall(function() require('nvim-claude.background_agent.commands').register(claude) end)
  pcall(function() require('nvim-claude.checkpoint.commands').register(claude) end)
  pcall(function() require('nvim-claude.chat.commands').register(claude) end)
  pcall(function() require('nvim-claude.debug.commands').register(claude) end)
  pcall(function() require('nvim-claude.lsp_mcp.commands').register(claude) end)
  pcall(function() require('nvim-claude.rpc.commands').register(claude) end)
end

return M
