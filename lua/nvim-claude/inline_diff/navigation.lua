-- Navigation utilities for hunks within a buffer, and file-level navigation

local M = {}

local utils = require 'nvim-claude.utils'
local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'

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

-- Below: file-level navigation helpers (edited items, list, next/prev)

local project_state = require 'nvim-claude.project-state'

local function get_edited_items()
  local root = utils.get_project_root()
  if not root then return root, {} end
  local map = project_state.get(root, 'claude_edited_files') or {}
  local baseline_ref = baseline.get_baseline_ref(root)
  local items, changed = {}, false
  for rel, v in pairs(map) do
    if v then
      local full = root .. '/' .. rel
      if vim.fn.filereadable(full) == 1 then
        local base_content = ''
        if baseline_ref and baseline_ref ~= '' then
          local cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", root, baseline_ref, rel)
          base_content = utils.exec(cmd) or ''
          if base_content:match('^fatal:') or base_content:match('^error:') then base_content = '' end
        end
        local current = utils.read_file(full) or ''
        local d = diffmod.compute_diff(base_content, current)
        if d and d.hunks and #d.hunks > 0 then
          table.insert(items, { rel = rel, deleted = false })
        else
          map[rel] = nil
          changed = true
        end
      else
        table.insert(items, { rel = rel, deleted = true })
      end
    end
  end
  if changed then project_state.set(root, 'claude_edited_files', map) end
  table.sort(items, function(a, b) return a.rel < b.rel end)
  return root, items
end

local function parse_deleted_rel(bufname)
  if type(bufname) ~= 'string' then return nil end
  return bufname:match('^%[deleted%]%s+(.+)$')
end

local function show_deleted_view(project_root, rel)
  local ref = baseline.get_baseline_ref(project_root)
  if not ref or ref == '' then return end
  local cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", project_root, ref, rel)
  local base = utils.exec(cmd) or ''
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = rel }) or ''
  vim.api.nvim_buf_set_name(buf, '[deleted] ' .. rel)
  local lines = {}
  if base ~= '' then lines = vim.split(base, '\n', { plain = true }) end
  if #lines > 0 and lines[#lines] == '' then table.remove(lines) end
  if #lines == 0 then lines = { '' } end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace('nvim_claude_deleted_view')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i = 0, #lines - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 0, { line_hl_group = 'DiffDelete' })
  end
  vim.bo[buf].modifiable = false

  -- Buffer-local actions to accept or reject deletion
  local function untrack()
    local map = project_state.get(project_root, 'claude_edited_files') or {}
    map[rel] = nil
    project_state.set(project_root, 'claude_edited_files', map)
  end

  local function accept_delete()
    local ref_now = baseline.get_baseline_ref(project_root)
    if ref_now and ref_now ~= '' then
      baseline.remove_from_baseline(project_root, rel, ref_now)
    end
    untrack()
    vim.notify('Accepted deletion: ' .. rel, vim.log.levels.INFO)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  local function reject_delete()
    local full = project_root .. '/' .. rel
    utils.ensure_dir(vim.fn.fnamemodify(full, ':h'))
    utils.write_file(full, base)
    untrack()
    vim.notify('Restored file: ' .. rel, vim.log.levels.INFO)
    vim.cmd('edit ' .. vim.fn.fnameescape(full))
  end

  vim.keymap.set('n', '<leader>iA', accept_delete, { buffer = buf, silent = true, desc = 'Accept deletion' })
  vim.keymap.set('n', '<leader>ia', accept_delete, { buffer = buf, silent = true, desc = 'Accept deletion' })
  vim.keymap.set('n', '<leader>iR', reject_delete, { buffer = buf, silent = true, desc = 'Reject deletion (restore)' })
  vim.keymap.set('n', '<leader>ir', reject_delete, { buffer = buf, silent = true, desc = 'Reject deletion (restore)' })
end

function M.get_edited_items()
  return get_edited_items()
end

function M.list_files()
  local root, items = get_edited_items()
  if not root or #items == 0 then
    vim.notify('No Claude-edited files to list', vim.log.levels.INFO)
    return
  end
  local display, idx_to_rel, idx_deleted = {}, {}, {}
  for i, it in ipairs(items) do
    table.insert(display, (it.deleted and ('[DELETED] ' .. it.rel) or it.rel))
    idx_to_rel[i] = it.rel; idx_deleted[i] = it.deleted
  end
  vim.ui.select(display, { prompt = 'Claude-edited files' }, function(choice, idx)
    if not choice or not idx then return end
    local rel, deleted = idx_to_rel[idx], idx_deleted[idx]
    local full = utils.get_project_root() .. '/' .. rel
    if deleted then show_deleted_view(root, rel) else vim.cmd('edit ' .. vim.fn.fnameescape(full)) end
  end)
end

function M.next_file()
  local root, items = get_edited_items()
  if not root or #items == 0 then return end
  local cur = vim.api.nvim_buf_get_name(0)
  local rel_cur = cur:gsub('^' .. vim.pesc(root) .. '/', '')
  rel_cur = parse_deleted_rel(cur) or rel_cur
  local idx = 0
  for i, it in ipairs(items) do if it.rel == rel_cur then idx = i break end end
  local next_idx = (idx % #items) + 1
  local it = items[next_idx]
  if it.deleted then show_deleted_view(root, it.rel) else vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. it.rel)) end
end

function M.prev_file()
  local root, items = get_edited_items()
  if not root or #items == 0 then return end
  local cur = vim.api.nvim_buf_get_name(0)
  local rel_cur = cur:gsub('^' .. vim.pesc(root) .. '/', '')
  rel_cur = parse_deleted_rel(cur) or rel_cur
  local idx = 1
  for i, it in ipairs(items) do if it.rel == rel_cur then idx = i break end end
  local prev_idx = (idx - 2) % #items + 1
  local it = items[prev_idx]
  if it.deleted then show_deleted_view(root, it.rel) else vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. it.rel)) end
end

-- Helpers to coordinate view switching for deleted-file scratch buffers
function M.close_current_deleted_view_if_any()
  local name = vim.api.nvim_buf_get_name(0)
  local rel = parse_deleted_rel(name)
  if rel then pcall(vim.api.nvim_buf_delete, 0, { force = true }) end
  return rel
end

function M.open_restored_if_was_deleted_view(project_root)
  local name = vim.api.nvim_buf_get_name(0)
  local rel = parse_deleted_rel(name)
  if rel and project_root then
    local full = project_root .. '/' .. rel
    pcall(vim.api.nvim_buf_delete, 0, { force = true })
    vim.schedule(function() vim.cmd('edit ' .. vim.fn.fnameescape(full)) end)
  end
end

return M
