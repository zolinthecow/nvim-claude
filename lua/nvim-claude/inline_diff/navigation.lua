-- Navigation utilities for hunks within a buffer

local M = {}

-- Compute the line range covered by a hunk in the new file
local function hunk_line_range(hunk)
  local start_line = hunk.new_start
  local line_offset = 0
  for _, line in ipairs(hunk.lines or {}) do
    if not line:match '^%-' then -- not a deletion
      line_offset = line_offset + 1
    end
  end
  local end_line = start_line + line_offset - 1
  if hunk.new_length == 0 then end_line = start_line end
  return start_line, end_line
end

function M.jump_to_hunk(bufnr, diff_data, hunk_idx, silent)
  if not diff_data or not diff_data.hunks or not diff_data.hunks[hunk_idx] then return end
  local hunk = diff_data.hunks[hunk_idx]
  diff_data.current_hunk = hunk_idx

  local jump_line = nil
  local new_line = hunk.new_start
  for _, line in ipairs(hunk.lines or {}) do
    if line:match '^%+' or line:match '^%-' then
      jump_line = new_line
      break
    elseif line:match '^%s' then
      new_line = new_line + 1
    end
  end
  if not jump_line then jump_line = hunk.new_start end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if jump_line > line_count then jump_line = math.max(1, line_count) end

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    vim.api.nvim_win_set_cursor(win, { jump_line, 0 })
  end
  if not silent then
    vim.notify(string.format('Hunk %d/%d', hunk_idx, #diff_data.hunks), vim.log.levels.INFO)
  end
end

function M.next_hunk(bufnr, diff_data)
  if not diff_data or not diff_data.hunks or #diff_data.hunks == 0 then return end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local next_idx, current_idx
  for i, h in ipairs(diff_data.hunks) do
    local s, e = hunk_line_range(h)
    if cursor_line >= s and cursor_line <= e then current_idx = i end
    if s > cursor_line and not next_idx then
      next_idx = i
      break
    end
  end
  if current_idx and current_idx < #diff_data.hunks then
    next_idx = current_idx + 1
  elseif not next_idx then
    next_idx = 1
  end
  M.jump_to_hunk(bufnr, diff_data, next_idx)
end

function M.prev_hunk(bufnr, diff_data)
  if not diff_data or not diff_data.hunks or #diff_data.hunks == 0 then return end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local prev_idx, current_idx
  for i = #diff_data.hunks, 1, -1 do
    local h = diff_data.hunks[i]
    local s, e = hunk_line_range(h)
    if cursor_line >= s and cursor_line <= e then current_idx = i end
    if s < cursor_line and not current_idx then
      prev_idx = i
      break
    end
  end
  if current_idx and current_idx > 1 then
    prev_idx = current_idx - 1
  elseif not prev_idx then
    prev_idx = #diff_data.hunks
  end
  M.jump_to_hunk(bufnr, diff_data, prev_idx)
end

return M

