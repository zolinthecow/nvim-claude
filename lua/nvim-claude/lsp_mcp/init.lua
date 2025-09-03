-- LSP/MCP façade: exposes diagnostics API without any inline-diff coupling

local M = {}

local function plugin_dir()
  local src = debug.getinfo(1, 'S').source:sub(2)
  local root = src:match('(.*/)lua/nvim%-claude/')
  if root and vim.fn.isdirectory(root .. 'mcp-server') == 1 then return root end
  local lazy = vim.fn.stdpath('data') .. '/lazy/nvim-claude/'
  if vim.fn.isdirectory(lazy .. 'mcp-server') == 1 then return lazy end
  local packer = vim.fn.stdpath('data') .. '/site/pack/packer/start/nvim-claude/'
  if vim.fn.isdirectory(packer .. 'mcp-server') == 1 then return packer end
  local dev = vim.fn.expand('~/.config/nvim/lua/nvim-claude/')
  if vim.fn.isdirectory(dev .. 'mcp-server') == 1 then return dev end
  return nil
end

local function install_script_path()
  local root = plugin_dir()
  return root and (root .. 'mcp-server/install.sh') or nil
end

function M.install()
  local script = install_script_path()
  if not script or vim.fn.filereadable(script) == 0 then
    vim.notify('nvim-claude: MCP install script not found', vim.log.levels.ERROR)
    return false
  end
  vim.notify('Installing MCP server dependencies...', vim.log.levels.INFO)
  vim.fn.jobstart({ 'bash', script }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify('✅ MCP server installed successfully', vim.log.levels.INFO)
      else
        vim.notify('❌ MCP installation failed. Check :messages for details', vim.log.levels.ERROR)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do if line ~= '' then vim.notify(line, vim.log.levels.WARN) end end
    end,
  })
  return true
end

function M.ensure_installed(opts)
  opts = opts or {}
  local install_path = opts.install_path or (vim.fn.stdpath('data') .. '/nvim-claude/mcp-env')
  local venv_python = install_path .. '/bin/python'
  if vim.fn.filereadable(venv_python) == 1 then
    local env_prefix = 'FASTMCP_LOG_LEVEL=INFO LOG_LEVEL=INFO '
    local ok_fast = vim.fn.system(string.format('%s%s -c "import fastmcp"', env_prefix, venv_python))
    local fastmcp = (vim.v.shell_error == 0)
    local _ = vim.fn.system(string.format('%s%s -c "import mcp"', env_prefix, venv_python))
    local mcp = (vim.v.shell_error == 0)
    if fastmcp or mcp then return true end
  end
  return M.install()
end

M.diagnostics = require('nvim-claude.lsp_mcp.diagnostics')

function M.show_setup_command()
  local root = plugin_dir()
  if not root then
    vim.notify('Could not find nvim-claude plugin directory', vim.log.levels.ERROR)
    vim.notify('Run :ClaudeInstallMCP first', vim.log.levels.ERROR)
    return
  end
  local mcp_server_path = root .. 'mcp-server/nvim-lsp-server.py'
  local venv_python = (vim.fn.stdpath('data') .. '/nvim-claude/mcp-env/bin/python')
  vim.notify('To configure nvim-lsp MCP server:', vim.log.levels.INFO)
  vim.notify('claude mcp add nvim-lsp -s local ' .. venv_python .. ' ' .. mcp_server_path, vim.log.levels.INFO)
  vim.notify('Then restart Claude Code in this directory.', vim.log.levels.INFO)
end

return M
