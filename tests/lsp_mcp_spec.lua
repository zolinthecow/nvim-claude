local eq = assert.are.equal
local truthy = assert.is_true

local diagnostics = require 'nvim-claude.lsp_mcp.diagnostics'

local function temp_lua_file()
  local path = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({ 'local value = 1', 'return value' }, path)
  return path
end

describe('lsp_mcp diagnostics buffer lifecycle', function()
  local paths = {}

  after_each(function()
    for _, path in ipairs(paths) do
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      vim.fn.delete(path)
    end
    paths = {}
  end)

  it('does not delete or detach an existing loaded buffer', function()
    local path = temp_lua_file()
    table.insert(paths, path)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()

    diagnostics.get_for_files({ path })

    truthy(vim.api.nvim_buf_is_valid(bufnr))
    truthy(vim.api.nvim_buf_is_loaded(bufnr))
    eq(vim.fn.resolve(path), vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr)))
    eq('local value = 1', vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  end)

  it('uses the real filename for context filetype detection and cleans up its buffer', function()
    local path = temp_lua_file()
    table.insert(paths, path)

    local result = vim.json.decode(diagnostics.get_context(path, 1))

    eq('lua', result.filetype)
    eq('local value = 1', result.context.lines[1])
    eq(-1, vim.fn.bufnr(path))
  end)

  it('returns an object for an empty diagnostics result', function()
    eq('{}', diagnostics.get_for_files({}))
  end)
end)
