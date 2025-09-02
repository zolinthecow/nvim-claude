-- LSP/MCP-related commands

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register(claude)
  -- Show MCP setup instruction (path to server)
  define('ClaudeShowMCPCommand', function()
    require('nvim-claude').show_mcp_setup_command()
  end, { desc = 'Show MCP server setup command' })

  -- Install MCP server deps
  define('ClaudeInstallMCP', function()
    local plugin_dir = require('nvim-claude').get_plugin_dir()
    if not plugin_dir then
      vim.notify('nvim-claude: Could not find plugin directory. Please report this issue.', vim.log.levels.ERROR)
      return
    end
    local install_script = plugin_dir .. 'mcp-server/install.sh'
    if vim.fn.filereadable(install_script) == 0 then
      vim.notify('nvim-claude: MCP install script not found at: ' .. install_script, vim.log.levels.ERROR)
      return
    end
    local function on_exit(_, code, _)
      if code == 0 then
        vim.notify('✅ MCP server installed successfully!', vim.log.levels.INFO)
        vim.notify('Run "claude mcp list" to verify installation', vim.log.levels.INFO)
      else
        vim.notify('❌ MCP installation failed. Check :messages for details', vim.log.levels.ERROR)
      end
    end
    vim.notify('Installing MCP server dependencies...', vim.log.levels.INFO)
    vim.fn.jobstart({ 'bash', install_script }, {
      on_exit = on_exit,
      on_stdout = function(_, data)
        for _, line in ipairs(data) do if line ~= '' then print(line) end end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do if line ~= '' then vim.notify(line, vim.log.levels.WARN) end end
      end,
    })
  end, { desc = 'Install Claude MCP server dependencies' })
end

return M

