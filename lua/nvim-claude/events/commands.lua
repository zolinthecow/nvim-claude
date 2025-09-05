-- User commands for events (install/uninstall, debug helpers)

local M = {}

local agent_provider = require 'nvim-claude.agent_provider'
local autocmds = require 'nvim-claude.events.autocmds'

function M.setup()
  -- Install hooks (via provider)
  vim.api.nvim_create_user_command('ClaudeInstallHooks', function()
    agent_provider.install_hooks()
  end, { desc = 'Install hooks for current provider (Claude)' })

  -- Uninstall hooks (via provider)
  vim.api.nvim_create_user_command('ClaudeUninstallHooks', function()
    agent_provider.uninstall_hooks()
  end, { desc = 'Uninstall hooks for current provider (Claude)' })

  -- Enable/refresh autocmds
  vim.api.nvim_create_user_command('ClaudeEventsEnable', function()
    autocmds.setup()
    vim.notify('nvim-claude: Events autocmds enabled', vim.log.levels.INFO)
  end, { desc = 'Enable events autocmds' })
end

return M
