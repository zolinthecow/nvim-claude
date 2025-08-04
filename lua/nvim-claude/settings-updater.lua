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

  -- Create a unique temp file for this project's nvim server address
  -- Use project path hash to ensure consistent filename
  local project_state = require 'nvim-claude.project-state'
  local project_key = project_state.get_project_key(project_root)
  local key_hash = vim.fn.sha256(project_key)
  
  -- Store in system temp directory
  -- Use XDG_RUNTIME_DIR if available, otherwise /tmp
  local temp_dir = vim.env.XDG_RUNTIME_DIR or '/tmp'
  local server_file = string.format('%s/nvim-claude-%s-server', temp_dir, key_hash:sub(1, 8))
  vim.fn.writefile({ server_addr }, server_file)
  
  -- Debug logging
  local logger = require('nvim-claude.logger')
  logger.debug('settings_updater', 'Writing server file', {
    server_addr = server_addr,
    server_file = server_file,
    temp_dir = temp_dir,
    project_key = project_key,
    key_hash = key_hash:sub(1, 8)
  })
  
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

