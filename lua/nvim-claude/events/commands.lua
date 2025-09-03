-- User commands for events (install/uninstall, debug helpers)

local M = {}

local installer = require 'nvim-claude.events.installer'
local autocmds = require 'nvim-claude.events.autocmds'

function M.setup()
  -- Install hooks
  vim.api.nvim_create_user_command('ClaudeInstallHooks', function()
    installer.install()
  end, { desc = 'Install Claude Code hooks for this project' })

  -- Uninstall hooks
  vim.api.nvim_create_user_command('ClaudeUninstallHooks', function()
    installer.uninstall()
  end, { desc = 'Uninstall Claude Code hooks for this project' })

  -- Enable/refresh autocmds
  vim.api.nvim_create_user_command('ClaudeEventsEnable', function()
    autocmds.setup()
    vim.notify('nvim-claude: Events autocmds enabled', vim.log.levels.INFO)
  end, { desc = 'Enable events autocmds' })
end

return M

