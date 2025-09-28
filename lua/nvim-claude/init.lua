-- nvim-claude: Claude integration for Neovim with tmux workflow
local M = {}

-- Default configuration
M.config = {
  tmux = {
    split_direction = 'h', -- horizontal split
    split_size = 40, -- 40% width
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
  chat = {
    targeted_prefill = nil,
  },
  mappings = {
    prefix = '<leader>c',
    quick_prefix = '<C-c>',
  },
  mcp = {
    auto_install = true, -- Automatically install MCP server on first use
    install_path = vim.fn.stdpath 'data' .. '/nvim-claude/mcp-env',
  },
  provider = {
    name = 'claude',
    claude = {
      spawn_command = 'claude',
      background_spawn = 'claude --dangerously-skip-permissions',
    },
  },
}

-- Validate configuration
local function validate_config(config)
  local ok = true
  local errors = {}

  -- Validate tmux settings
  if config.tmux then
    if config.tmux.split_direction and config.tmux.split_direction ~= 'h' and config.tmux.split_direction ~= 'v' then
      table.insert(errors, "tmux.split_direction must be 'h' or 'v'")
      ok = false
    end

    if config.tmux.split_size and (type(config.tmux.split_size) ~= 'number' or config.tmux.split_size < 1 or config.tmux.split_size > 99) then
      table.insert(errors, 'tmux.split_size must be a number between 1 and 99')
      ok = false
    end
  end

  -- Validate agent settings
  if config.agents then
    if config.agents.max_agents and (type(config.agents.max_agents) ~= 'number' or config.agents.max_agents < 1) then
      table.insert(errors, 'agents.max_agents must be a positive number')
      ok = false
    end

    if config.agents.cleanup_days and (type(config.agents.cleanup_days) ~= 'number' or config.agents.cleanup_days < 0) then
      table.insert(errors, 'agents.cleanup_days must be a non-negative number')
      ok = false
    end

    if config.agents.work_dir and (type(config.agents.work_dir) ~= 'string' or config.agents.work_dir:match '^/' or config.agents.work_dir:match '%.%.') then
      table.insert(errors, "agents.work_dir must be a relative path without '..'")
      ok = false
    end
  end

  -- Validate mappings
  if config.mappings then
    if config.mappings.prefix and type(config.mappings.prefix) ~= 'string' then
      table.insert(errors, 'mappings.prefix must be a string')
      ok = false
    end
  end

  if config.chat then
    if config.chat.targeted_prefill ~= nil and type(config.chat.targeted_prefill) ~= 'string' then
      table.insert(errors, 'chat.targeted_prefill must be a string if provided')
      ok = false
    end
  end

  -- Validate provider config
  if config.provider then
    if config.provider.name and type(config.provider.name) ~= 'string' then
      table.insert(errors, 'provider.name must be a string')
      ok = false
    end
    local name = config.provider.name or 'claude'
    if name ~= 'claude' and name ~= 'codex' then
      table.insert(errors, "provider.name must be 'claude' or 'codex'")
      ok = false
    end
    local opts = config.provider[name]
    if opts and type(opts) ~= 'table' then
      table.insert(errors, string.format("provider.%s must be a table", name))
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

-- Install helpers have moved to rpc/ and lsp_mcp/ facades

-- Helper function to find plugin directory
function M.get_plugin_dir()
  -- 1. Check if we're in development (source path contains lua/nvim-claude)
  local source_path = debug.getinfo(1, 'S').source:sub(2)
  if source_path:match 'lua/nvim%-claude' then
    -- Extract path up to and including nvim-claude root
    local plugin_dir = source_path:match '(.*/)lua/nvim%-claude/'
    if plugin_dir and vim.fn.isdirectory(plugin_dir .. 'mcp-server') == 1 then
      return plugin_dir
    end
  end

  -- 2. Try lazy.nvim location
  local lazy_dir = vim.fn.stdpath 'data' .. '/lazy/nvim-claude/'
  if vim.fn.isdirectory(lazy_dir .. 'mcp-server') == 1 then
    return lazy_dir
  end

  -- 3. Try packer location
  local packer_dir = vim.fn.stdpath 'data' .. '/site/pack/packer/start/nvim-claude/'
  if vim.fn.isdirectory(packer_dir .. 'mcp-server') == 1 then
    return packer_dir
  end

  -- 4. Try development location
  local dev_dir = vim.fn.expand '~/.config/nvim/lua/nvim-claude/'
  if vim.fn.isdirectory(dev_dir .. 'mcp-server') == 1 then
    return dev_dir
  end

  -- 5. Debug: show what we found
  vim.notify('nvim-claude: Could not find mcp-server directory', vim.log.levels.WARN)
  vim.notify('Searched in:', vim.log.levels.INFO)
  vim.notify('  - ' .. lazy_dir .. ' (lazy.nvim)', vim.log.levels.INFO)
  vim.notify('  - ' .. packer_dir .. ' (packer)', vim.log.levels.INFO)
  vim.notify('  - ' .. dev_dir .. ' (development)', vim.log.levels.INFO)
  vim.notify('\nThis might happen if:', vim.log.levels.INFO)
  vim.notify('  1. The plugin was not fully cloned', vim.log.levels.INFO)
  vim.notify('  2. Your package manager excluded the mcp-server directory', vim.log.levels.INFO)
  vim.notify('\nTry reinstalling the plugin or check your package manager config', vim.log.levels.INFO)

  return nil
end

-- Plugin setup
function M.setup(user_config)
  M.config = merge_config(user_config)

  -- If running in headless mode, only set up minimal functionality
  if vim.g.headless_mode then
    -- Load the LSP/MCP modules for headless operation
    M.lsp_mcp = require 'nvim-claude.lsp_mcp'
    M.logger = require 'nvim-claude.logger'
    return
  end

  -- Check plugin integrity early
  vim.defer_fn(function()
    local plugin_dir = M.get_plugin_dir()
    if not plugin_dir then
      vim.notify('nvim-claude: Warning - mcp-server directory not found!', vim.log.levels.WARN)
      vim.notify('Some features may not work. Run :ClaudeDebugInstall for details', vim.log.levels.WARN)
    end
  end, 100)

  -- Force reload modules to ensure latest code
  package.loaded['nvim-claude.diff-review'] = nil

  -- Load submodules
  M.utils = require 'nvim-claude.utils'
  M.tmux = M.utils.tmux
  M.git = M.utils.git
  M.commands = require 'nvim-claude.commands'
  M.events = require 'nvim-claude.events'
  M.agent_provider = require 'nvim-claude.agent_provider'
  M.settings_updater = require 'nvim-claude.settings-updater'
  M.background_agent = require 'nvim-claude.background_agent'

  -- Initialize submodules with config
  M.tmux.setup(M.config.tmux)
  M.git.setup(M.config.agents)
  -- Initialize provider system (Claude-only for now); thread provider-specific options
  do
    local prov = M.config.provider or {}
    local name = prov.name or 'claude'
    local prov_opts = prov[name] or {}
    local opts = { provider = name }
    opts[name] = prov_opts
    M.agent_provider.setup(opts)
  end
  M.background_agent.registry_setup(M.config.agents)
  M.events.setup()

  -- Migrate old local state if needed (deferred to not slow startup)
  vim.defer_fn(function()
    local project_root = M.utils.get_project_root()
    if project_root then
      local project_state = require 'nvim-claude.project-state'
      if project_state.migrate_local_state(project_root) then
        vim.notify('nvim-claude: Migrated local state to global storage', vim.log.levels.INFO)
      end
    end
  end, 1000)
  M.settings_updater.setup()

  -- Check and install RPC client (needed for hooks to work)
  pcall(require('nvim-claude.rpc').ensure_installed)

  -- Check and install MCP server if configured
  if M.config.mcp.auto_install then
    pcall(require('nvim-claude.lsp_mcp').ensure_installed, M.config.mcp)
  end

  -- Set up commands via aggregator
  if M.commands and M.commands.register_all then
    M.commands.register_all(M)
  end

  -- Note: Hook installation is handled by settings-updater.setup()
  -- which runs on VimEnter and uses the proxy scripts

  -- Set up keymappings if enabled
  if M.config.mappings then
    require('nvim-claude.mappings').setup(M.config.mappings, nil)
  end

  -- Plugin loaded successfully
end

return M
