-- Installer: write Claude Code hook config into .claude/settings.local.json

-- Back-compat thin wrapper: delegate to provider installer

local M = {}

function M.install()
  return require('nvim-claude.agent_provider').install_hooks()
end

function M.uninstall()
  return require('nvim-claude.agent_provider').uninstall_hooks()
end

return M
