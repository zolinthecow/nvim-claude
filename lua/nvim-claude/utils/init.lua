-- Facade for nvim-claude utils
-- Exposes core utils and attaches namespaced modules (e.g., .git)
local core = require('nvim-claude.utils.core')

local M = {}

-- Merge core utilities into the facade
for k, v in pairs(core) do
  M[k] = v
end

-- Attach namespaced modules
M.git = require('nvim-claude.utils.git')
M.tmux = require('nvim-claude.utils.tmux')

return M
