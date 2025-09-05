-- Claude provider: hook install/uninstall wrappers

local M = {}

function M.install()
  return require('nvim-claude.events').install_hooks()
end

function M.uninstall()
  return require('nvim-claude.events').uninstall_hooks()
end

return M

