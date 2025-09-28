local utils = require('nvim-claude.utils')

local M = {}

local function get_lines(bufnr, line_start, line_end)
  if line_end < line_start then
    line_start, line_end = line_end, line_start
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, line_start - 1, line_end, false)
  if #lines == 0 then
    table.insert(lines, '')
  end
  return lines
end

function M.format_selection(bufnr, line_start, line_end)
  bufnr = bufnr or 0
  line_start = line_start or 1
  line_end = line_end or line_start

  local lines = get_lines(bufnr, line_start, line_end)
  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local rel = file_path ~= '' and file_path or vim.fn.expand('%:t')
  if git_root and git_root ~= '' then
    rel = rel:gsub('^' .. vim.pesc(git_root) .. '/', '')
  end
  local filetype = vim.bo[bufnr].filetype or ''
  local header = string.format('Selection from `%s` (lines %d-%d):', rel, line_start, line_end)
  local fence = '```' .. (filetype ~= '' and filetype or '')
  local message_lines = { header, fence }
  for _, l in ipairs(lines) do
    table.insert(message_lines, l)
  end
  table.insert(message_lines, '```')

  return {
    message = table.concat(message_lines, '\n'),
    header = header,
    rel_path = rel,
    filetype = filetype,
    code_lines = lines,
    code_block = table.concat(lines, '\n'),
    start_line = line_start,
    end_line = line_end,
  }
end

return M
