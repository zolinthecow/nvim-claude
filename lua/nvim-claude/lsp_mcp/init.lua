-- LSP/MCP façade: exposes diagnostics API without any inline-diff coupling

local M = {}

M.diagnostics = require('nvim-claude.lsp_mcp.diagnostics')

return M

