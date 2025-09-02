-- LSP/MCP-related commands

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register(claude)
  -- Show MCP setup instruction
  define('ClaudeShowMCPCommand', function()
    require('nvim-claude.lsp_mcp').show_setup_command()
  end, { desc = 'Show MCP server setup command' })

  -- Install MCP server deps via façade
  define('ClaudeInstallMCP', function()
    require('nvim-claude.lsp_mcp').install()
  end, { desc = 'Install Claude MCP server dependencies' })
end

return M
