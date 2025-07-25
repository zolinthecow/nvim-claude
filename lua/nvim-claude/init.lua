-- nvim-claude: Claude integration for Neovim with tmux workflow
local M = {}

-- Default configuration
M.config = {
  tmux = {
    split_direction = 'h',  -- horizontal split
    split_size = 40,        -- 40% width
    session_prefix = 'claude-',
    pane_title = 'claude-chat',
  },
  agents = {
    work_dir = '.agent-work',
    use_worktrees = true,
    auto_gitignore = true,
    max_agents = 5,
    cleanup_days = 7,
  },
  ui = {
    float_diff = true,
    telescope_preview = true,
    status_line = true,
  },
  mappings = {
    prefix = '<leader>c',
    quick_prefix = '<C-c>',
  },
  mcp = {
    auto_install = true,  -- Automatically install MCP server on first use
    install_path = vim.fn.stdpath('data') .. '/nvim-claude/mcp-env',
  },
}

-- Validate configuration
local function validate_config(config)
  local ok = true
  local errors = {}
  
  -- Validate tmux settings
  if config.tmux then
    if config.tmux.split_direction and 
       config.tmux.split_direction ~= 'h' and 
       config.tmux.split_direction ~= 'v' then
      table.insert(errors, "tmux.split_direction must be 'h' or 'v'")
      ok = false
    end
    
    if config.tmux.split_size and 
       (type(config.tmux.split_size) ~= 'number' or 
        config.tmux.split_size < 1 or 
        config.tmux.split_size > 99) then
      table.insert(errors, "tmux.split_size must be a number between 1 and 99")
      ok = false
    end
  end
  
  -- Validate agent settings
  if config.agents then
    if config.agents.max_agents and 
       (type(config.agents.max_agents) ~= 'number' or 
        config.agents.max_agents < 1) then
      table.insert(errors, "agents.max_agents must be a positive number")
      ok = false
    end
    
    if config.agents.cleanup_days and 
       (type(config.agents.cleanup_days) ~= 'number' or 
        config.agents.cleanup_days < 0) then
      table.insert(errors, "agents.cleanup_days must be a non-negative number")
      ok = false
    end
    
    if config.agents.work_dir and 
       (type(config.agents.work_dir) ~= 'string' or 
        config.agents.work_dir:match('^/') or
        config.agents.work_dir:match('%.%.')) then
      table.insert(errors, "agents.work_dir must be a relative path without '..'")
      ok = false
    end
  end
  
  -- Validate mappings
  if config.mappings then
    if config.mappings.prefix and 
       type(config.mappings.prefix) ~= 'string' then
      table.insert(errors, "mappings.prefix must be a string")
      ok = false
    end
  end
  
  return ok, errors
end

-- Merge user config with defaults
local function merge_config(user_config)
  local merged = vim.tbl_deep_extend('force', M.config, user_config or {})
  
  -- Validate the merged config
  local ok, errors = validate_config(merged)
  if not ok then
    vim.notify('nvim-claude: Configuration errors:', vim.log.levels.ERROR)
    for _, err in ipairs(errors) do
      vim.notify('  - ' .. err, vim.log.levels.ERROR)
    end
    vim.notify('Using default configuration', vim.log.levels.WARN)
    return M.config
  end
  
  return merged
end

-- Check and install MCP server
function M.check_and_install_mcp()
  local install_path = M.config.mcp.install_path or vim.fn.stdpath('data') .. '/nvim-claude/mcp-env'
  local venv_python = install_path .. '/bin/python'
  
  
  -- Check if MCP is already installed
  if vim.fn.filereadable(venv_python) == 1 then
    -- Check if either fastmcp or mcp is installed
    -- Set environment variables to uppercase as fastmcp expects
    local env_prefix = 'FASTMCP_LOG_LEVEL=INFO LOG_LEVEL=INFO '
    local check_cmd = string.format('%s%s -c "import fastmcp"', env_prefix, venv_python)
    local result = vim.fn.system(check_cmd)
    local fastmcp_installed = vim.v.shell_error == 0
    
    
    local check_mcp_cmd = string.format('%s%s -c "import mcp"', env_prefix, venv_python)
    vim.fn.system(check_mcp_cmd)
    local mcp_installed = vim.v.shell_error == 0
    
    if fastmcp_installed or mcp_installed then
      -- Either fastmcp or mcp is installed, check if user has configured it
      M.check_mcp_configuration()
      return -- Already installed
    else
      -- Alternative check: see if the MCP server script can run
      local server_script = vim.fn.expand('~/.config/nvim/lua/nvim-claude/mcp-server/nvim-lsp-server.py')
      local check_server = {venv_python, server_script, '--help'}
      vim.fn.system(check_server)
      if vim.v.shell_error == 0 then
        -- Server works, skip reinstall
        M.check_mcp_configuration()
        return
      end
    end
  end
  
  -- Install MCP server
  vim.notify('nvim-claude: Installing MCP server dependencies...', vim.log.levels.INFO)
  
  -- Get plugin directory - handle both development and installed paths
  local source_path = debug.getinfo(1, 'S').source:sub(2)
  local plugin_dir = source_path:match('(.*/)')
  
  -- For development, the actual plugin files might be in .config/nvim/lua/nvim-claude
  local dev_plugin_dir = vim.fn.expand('~/.config/nvim/lua/nvim-claude/')
  if vim.fn.isdirectory(dev_plugin_dir .. 'mcp-server') == 1 then
    plugin_dir = dev_plugin_dir
  end
  
  local install_script = plugin_dir .. 'mcp-server/install.sh'
  
  -- Check if install script exists
  if vim.fn.filereadable(install_script) == 0 then
    vim.notify('nvim-claude: MCP install script not found', vim.log.levels.ERROR)
    return
  end
  
  -- Run installation in background
  vim.fn.jobstart({'bash', install_script}, {
    on_exit = function(_, code, _)
      if code == 0 then
        vim.notify('nvim-claude: MCP server installed successfully!', vim.log.levels.INFO)
        -- Use development path if available
        local mcp_server_path = plugin_dir .. 'mcp-server/nvim-lsp-server.py'
        if not vim.fn.filereadable(mcp_server_path) and vim.fn.filereadable(dev_plugin_dir .. 'mcp-server/nvim-lsp-server.py') then
          mcp_server_path = dev_plugin_dir .. 'mcp-server/nvim-lsp-server.py'
        end
        vim.notify('Run "claude mcp add nvim-lsp -s local ' .. venv_python .. ' ' .. 
                   mcp_server_path .. '" to complete setup', 
                   vim.log.levels.INFO)
      else
        vim.notify('nvim-claude: MCP installation failed', vim.log.levels.ERROR)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then
          vim.notify('MCP install: ' .. line, vim.log.levels.WARN)
        end
      end
    end,
  })
end

-- Check if MCP is configured with Claude Code
function M.check_mcp_configuration()
  -- For now, we'll disable the configuration check since Claude Code stores
  -- local MCP configurations in its internal database, not in easily checkable files.
  -- The -s local flag stores configs in ~/.claude/__store.db or similar internal storage.
  
  -- Users who want to see the setup command can run :ClaudeShowMCPCommand
  -- This avoids annoying notifications while still providing the info when needed.
  
  -- Uncomment the next line to re-enable the old behavior:
  -- M.check_mcp_configuration_old()
end

-- Show MCP setup command on demand
function M.show_mcp_setup_command()
  local source_path = debug.getinfo(1, 'S').source:sub(2)
  local plugin_dir = source_path:match('(.*/)')
  
  -- For development, use the actual location
  local dev_plugin_dir = vim.fn.expand('~/.config/nvim/lua/nvim-claude/')
  local mcp_server_path = plugin_dir .. 'mcp-server/nvim-lsp-server.py'
  if vim.fn.filereadable(dev_plugin_dir .. 'mcp-server/nvim-lsp-server.py') == 1 then
    mcp_server_path = dev_plugin_dir .. 'mcp-server/nvim-lsp-server.py'
  end
  
  local venv_python = (M.config.mcp.install_path or vim.fn.stdpath('data') .. '/nvim-claude/mcp-env') .. '/bin/python'
  
  vim.notify('To configure nvim-lsp MCP server:', vim.log.levels.INFO)
  vim.notify('claude mcp add nvim-lsp -s local ' .. venv_python .. ' ' .. 
             mcp_server_path, vim.log.levels.INFO)
  vim.notify('Then restart Claude Code in this directory.', vim.log.levels.INFO)
end

-- Plugin setup
function M.setup(user_config)
  M.config = merge_config(user_config)
  
  -- Force reload modules to ensure latest code
  package.loaded['nvim-claude.hooks'] = nil
  package.loaded['nvim-claude.diff-review'] = nil
  
  -- Load submodules
  M.tmux = require('nvim-claude.tmux')
  M.git = require('nvim-claude.git')
  M.utils = require('nvim-claude.utils')
  M.commands = require('nvim-claude.commands')
  M.registry = require('nvim-claude.registry')
  M.hooks = require('nvim-claude.hooks')
  M.diff_review = require('nvim-claude.diff-review')
  M.settings_updater = require('nvim-claude.settings-updater')
  
  -- Initialize submodules with config
  M.tmux.setup(M.config.tmux)
  M.git.setup(M.config.agents)
  M.registry.setup(M.config.agents)
  M.hooks.setup()
  M.diff_review.setup()
  M.settings_updater.setup()
  
  -- Check and install MCP server if configured
  if M.config.mcp.auto_install then
    M.check_and_install_mcp()
  end
  
  -- Set up commands
  M.commands.setup(M)
  M.hooks.setup_commands()
  
  -- Note: Hook installation is handled by settings-updater.setup()
  -- which runs on VimEnter and uses the proxy scripts
  
  -- Set up keymappings if enabled
  if M.config.mappings then
    require('nvim-claude.mappings').setup(M.config.mappings, M.commands)
  end
  
  -- Plugin loaded successfully
end

return M 