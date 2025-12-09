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

  -- Manage Codex OTEL relay daemon (Codex provider only)
  vim.api.nvim_create_user_command('ClaudeStartCodexRelay', function()
    local relay_ok = false
    local ok, relay = pcall(require, 'nvim-claude.agent_provider.providers.codex.relay')
    if ok and relay then
      relay_ok = relay.ensure_running()
    end
    if relay_ok then
      vim.notify('nvim-claude: Codex OTEL relay running', vim.log.levels.INFO)
    else
      vim.notify('nvim-claude: Failed to start Codex OTEL relay', vim.log.levels.ERROR)
    end
  end, { desc = 'Start Codex OTEL relay daemon' })

  vim.api.nvim_create_user_command('ClaudeStopCodexRelay', function()
    local ok, relay = pcall(require, 'nvim-claude.agent_provider.providers.codex.relay')
    if ok and relay then
      relay.stop()
    else
      vim.notify('nvim-claude: Codex relay module unavailable', vim.log.levels.WARN)
    end
  end, { desc = 'Stop Codex OTEL relay daemon' })

  vim.api.nvim_create_user_command('ClaudeCodexOtelHealth', function()
    local ok, relay = pcall(require, 'nvim-claude.agent_provider.providers.codex.relay')
    if not ok or not relay then
      vim.notify('nvim-claude: Codex relay module unavailable', vim.log.levels.WARN)
      return
    end
    local h = relay.health()
    local lines = {
      'Codex OTEL relay health:',
      string.format('  use_daemon: %s', tostring(h.use_daemon)),
      string.format('  running:   %s', tostring(h.running)),
      string.format('  listening: %s', tostring(h.listening)),
      string.format('  pid:       %s', h.pid or 'none'),
      string.format('  port:      %s', h.port or 'unknown'),
      string.format('  pid_file:  %s', h.pid_file or 'unknown'),
      string.format('  log_file:  %s', h.log_file or 'unknown'),
    }
    vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
  end, { desc = 'Show Codex OTEL relay health' })
end

return M
