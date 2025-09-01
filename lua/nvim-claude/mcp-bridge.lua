---@diagnostic disable: undefined-global
-- MCP bridge: thin adapter over lsp_mcp diagnostics
local M = {}

local lsp_mcp = require('nvim-claude.lsp_mcp')

function M.get_diagnostics(file_paths)
  return lsp_mcp.diagnostics.get_for_files(file_paths)
end

function M.get_diagnostic_context(file_path, line)
  return lsp_mcp.diagnostics.get_context(file_path, line)
end

function M.get_diagnostic_summary()
  return lsp_mcp.diagnostics.get_summary()
end

function M.get_session_diagnostics()
  return lsp_mcp.diagnostics.get_session()
end

-- Async wrappers that write to a named pipe
function M.get_diagnostics_async(pipe_path, file_paths)
  vim.defer_fn(function()
    local result = lsp_mcp.diagnostics.get_for_files(file_paths)
    local pipe = io.open(pipe_path, 'w')
    if pipe then pipe:write(result) pipe:close() end
  end, 0)
end

function M.get_diagnostic_context_async(pipe_path, file_path, line)
  vim.defer_fn(function()
    local result = lsp_mcp.diagnostics.get_context(file_path, line)
    local pipe = io.open(pipe_path, 'w')
    if pipe then pipe:write(result) pipe:close() end
  end, 0)
end

function M.get_diagnostic_summary_async(pipe_path)
  vim.defer_fn(function()
    local result = lsp_mcp.diagnostics.get_summary()
    local pipe = io.open(pipe_path, 'w')
    if pipe then pipe:write(result) pipe:close() end
  end, 0)
end

function M.get_session_diagnostics_async(pipe_path)
  vim.defer_fn(function()
    local result = lsp_mcp.diagnostics.get_session()
    local pipe = io.open(pipe_path, 'w')
    if pipe then pipe:write(result) pipe:close() end
  end, 0)
end

return M

