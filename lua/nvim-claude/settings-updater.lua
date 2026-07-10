local M = {}
local utils = require 'nvim-claude.utils'
local logger = require 'nvim-claude.logger'
local project_state = require 'nvim-claude.project-state'
local agent_provider = require 'nvim-claude.agent_provider'

local function project_server_file(project_root)
  if not project_root or project_root == '' then return nil end
  local project_key = project_state.get_project_key(project_root)
  local key_hash = vim.fn.sha256(project_key)
  local temp_dir = vim.env.XDG_RUNTIME_DIR or '/tmp'
  return string.format('%s/nvim-claude-%s-server', temp_dir, key_hash:sub(1, 8))
end

local function ensure_server_file(project_root)
  project_root = project_root or utils.get_project_root()
  if not project_root then
    return
  end

  local server_addr = vim.v.servername
  if not server_addr or server_addr == '' then
    return
  end

  local server_file = project_server_file(project_root)
  if not server_file then return end

  local current = nil
  if vim.fn.filereadable(server_file) == 1 then
    local lines = vim.fn.readfile(server_file)
    current = (lines and lines[1]) or nil
  end
  if current ~= server_addr then
    vim.fn.writefile({ server_addr }, server_file)
  end

  logger.debug('settings_updater', 'Ensured server file', {
    server_addr = server_addr,
    server_file = server_file,
  })
end

-- Update Claude settings with current Neovim server address
function M.update_claude_settings()
  -- Skip if running in headless mode (MCP server)
  if vim.g.headless_mode then
    return
  end
  
  local project_root = utils.get_project_root()
  if not project_root then
    return
  end

  ensure_server_file(project_root)
  
  -- Migrate old .nvim-server file if it exists
  local old_server_file = project_root .. '/.nvim-server'
  if utils.file_exists(old_server_file) then
    os.remove(old_server_file)
  end

  -- Install/update provider hook settings for current provider
  agent_provider.install_hooks()
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

  vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained' }, {
    group = vim.api.nvim_create_augroup('NvimClaudeServerFileRefresh', { clear = true }),
    callback = function()
      vim.defer_fn(function()
        ensure_server_file()
      end, 100)
    end,
  })
end

-- Alias for consumers that prefer a "refresh" semantics
M.refresh = M.update_claude_settings

return M
