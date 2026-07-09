-- Aggregated command registration (new structure)
-- Each register_* function defines user commands for a feature area.
-- Call register_all() from init once migration is complete.

local M = {}
local logger = require 'nvim-claude.logger'

-- Background agent commands are registered by feature module

-- Checkpoint commands
function M.register_checkpoints() end

function M.register_all(claude)
  local modules = {
    {
      name = 'nvim-claude.background_agent.commands',
      load = function() return require 'nvim-claude.background_agent.commands' end,
    },
    {
      name = 'nvim-claude.checkpoint.commands',
      load = function() return require 'nvim-claude.checkpoint.commands' end,
    },
    {
      name = 'nvim-claude.chat.commands',
      load = function() return require 'nvim-claude.chat.commands' end,
    },
    {
      name = 'nvim-claude.debug.commands',
      load = function() return require 'nvim-claude.debug.commands' end,
    },
    {
      name = 'nvim-claude.lsp_mcp.commands',
      load = function() return require 'nvim-claude.lsp_mcp.commands' end,
    },
    {
      name = 'nvim-claude.rpc.commands',
      load = function() return require 'nvim-claude.rpc.commands' end,
    },
  }
  local errors = {}

  for _, module in ipairs(modules) do
    local loaded, registrar = pcall(module.load)
    if not loaded then
      table.insert(errors, { module = module.name, error = registrar })
    elseif type(registrar.register) ~= 'function' then
      table.insert(errors, { module = module.name, error = 'missing register function' })
    else
      local registered, err = pcall(registrar.register, claude)
      if not registered then table.insert(errors, { module = module.name, error = err }) end
    end
  end

  for _, failure in ipairs(errors) do
    logger.error('commands', 'Failed to register feature commands', failure)
  end
  if #errors > 0 then
    vim.notify(string.format('nvim-claude: %d command module(s) failed to register; see logs', #errors), vim.log.levels.ERROR)
  end
  return #errors == 0, errors
end

return M
