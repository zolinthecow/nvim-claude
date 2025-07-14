local M = {}
local utils = require 'nvim-claude.utils'

-- Update Claude settings with current Neovim server address
function M.update_claude_settings()
  local project_root = utils.get_project_root()
  if not project_root then
    return
  end

  -- Get current Neovim server address
  local server_addr = vim.v.servername
  if not server_addr or server_addr == '' then
    -- If no servername, we can't communicate
    return
  end

  -- Ensure .nvim-claude directory exists
  local nvim_claude_dir = project_root .. '/.nvim-claude'
  utils.ensure_dir(nvim_claude_dir)
  
  -- Write server address to project-specific file for proxy script
  local server_file = nvim_claude_dir .. '/nvim-server'
  vim.fn.writefile({ server_addr }, server_file)
  
  -- Migrate old .nvim-server file if it exists
  local old_server_file = project_root .. '/.nvim-server'
  if utils.file_exists(old_server_file) then
    os.remove(old_server_file)
  end

  -- Use the install_hooks function from hooks module to update settings
  local hooks = require 'nvim-claude.hooks'
  hooks.install_hooks()
end

-- Setup autocmds to update settings
function M.setup()
  vim.api.nvim_create_autocmd({ 'VimEnter', 'DirChanged' }, {
    group = vim.api.nvim_create_augroup('NvimClaudeSettingsUpdater', { clear = true }),
    callback = function()
      -- Defer to ensure servername is available
      vim.defer_fn(function()
        M.update_claude_settings()
      end, 500)
    end,
  })
end

return M

