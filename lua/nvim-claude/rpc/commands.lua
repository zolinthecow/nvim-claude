-- RPC client install command

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register()
  define('ClaudeInstallRPC', function()
    require('nvim-claude.rpc').install()
  end, { desc = 'Install nvim-claude RPC client (pynvim)' })
end

return M
