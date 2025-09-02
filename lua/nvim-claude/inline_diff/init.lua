-- Facade for inline diff functionality (modular API)

local M = {}

local utils = require 'nvim-claude.utils'
local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'
local render = require 'nvim-claude.inline_diff.render'
local hunks = require 'nvim-claude.inline_diff.hunks'
local exec = require 'nvim-claude.inline_diff.executor'
local nav = require 'nvim-claude.inline_diff.navigation'
local persist = require 'nvim-claude.inline_diff.persistence'
local events = require 'nvim-claude.events'

-- Private state: active diffs per buffer
local active_diffs = {}

-- --- Baseline API ---
function M.get_baseline_ref(git_root) return baseline.get_baseline_ref(git_root) end
function M.set_baseline_ref(git_root, ref) return baseline.set_baseline_ref(git_root, ref) end
function M.clear_baseline_ref(git_root) return baseline.clear_baseline_ref(git_root) end
function M.create_baseline(message) return baseline.create_baseline(message) end

-- Update a single file's content inside the current baseline commit
-- Returns true on success
function M.update_baseline_file(git_root, relative_path, new_content)
  git_root = git_root or utils.get_project_root()
  if not git_root then return false end
  local ref = baseline.get_baseline_ref(git_root)
  if not ref then return false end
  return baseline.update_baseline_with_content(git_root, relative_path, new_content or '', ref)
end

-- --- Diff state helpers (read-only) ---
function M.has_active_diff(bufnr) return active_diffs[bufnr] ~= nil end
function M.get_diff_state(bufnr)
  local d = active_diffs[bufnr]
  if not d then return nil end
  return { hunks = d.hunks, current_hunk = d.current_hunk }
end
function M.set_current_hunk(bufnr, idx)
  if active_diffs[bufnr] then active_diffs[bufnr].current_hunk = idx end
end

-- --- Visualization entry points ---
function M.show_inline_diff(bufnr, old_content, new_content, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local d = diffmod.compute_diff(old_content or '', new_content or '')
  if not d or not d.hunks or #d.hunks == 0 then return end
  active_diffs[bufnr] = { hunks = d.hunks, current_hunk = 1 }
  render.apply_diff_visualization(bufnr, active_diffs[bufnr])
  if not opts.preserve_cursor then nav.jump_to_hunk(bufnr, active_diffs[bufnr], 1, true) end
end

function M.refresh_inline_diff(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return exec.recompute_and_render(bufnr, active_diffs)
end

function M.close_inline_diff(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Clear visuals by rendering empty diff (no-op) and dropping state
  active_diffs[bufnr] = nil
  -- Explicitly clear namespace visuals
  local ns_id = vim.api.nvim_create_namespace 'nvim_claude_inline_diff'
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

-- --- Navigation ---
function M.jump_to_hunk(bufnr, idx, silent)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local d = active_diffs[bufnr]
  if not d then return end
  nav.jump_to_hunk(bufnr, d, idx, silent)
end
function M.next_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local d = active_diffs[bufnr]
  if not d then return end
  nav.next_hunk(bufnr, d)
end
function M.prev_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local d = active_diffs[bufnr]
  if not d then return end
  nav.prev_hunk(bufnr, d)
end

-- --- Accept / Reject operations ---
local function apply_and_redraw(bufnr, plan)
  return exec.apply_plan_and_redraw(bufnr, plan, active_diffs)
end

function M.accept_current_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.accept_current_hunk(bufnr, active_diffs)
  return apply_and_redraw(bufnr, plan)
end

function M.reject_current_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.reject_current_hunk(bufnr, active_diffs)
  return apply_and_redraw(bufnr, plan)
end

function M.accept_all_hunks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.accept_all_hunks_in_file(bufnr)
  return apply_and_redraw(bufnr, plan)
end

function M.reject_all_hunks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.reject_all_hunks_in_file(bufnr)
  return apply_and_redraw(bufnr, plan)
end

function M.accept_all_files()
  local plan = hunks.accept_all_hunks_in_all_files(active_diffs)
  exec.run_actions(plan.actions)
  -- Redraw all buffers that still have diffs
  for bufnr, _ in pairs(active_diffs) do M.refresh_inline_diff(bufnr) end
end

function M.reject_all_files()
  local plan = hunks.reject_all_hunks_in_all_files(active_diffs)
  exec.run_actions(plan.actions)
  for bufnr, _ in pairs(active_diffs) do M.refresh_inline_diff(bufnr) end
end

-- Clear persistence state for inline diffs (project-state)
function M.clear_persistence(git_root)
  return persist.clear_state(git_root)
end

-- --- File navigation helpers (across project files with Claude edits) ---
local function project_files_with_diffs()
  local root = utils.get_project_root()
  if not root then return root, {} end
  local list = events.list_edited_files(root)
  return root, list
end

local function current_relative_path(project_root)
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == '' then return nil end
  return abs:gsub('^' .. vim.pesc(project_root) .. '/', '')
end

function M.list_diff_files()
  local root, files = project_files_with_diffs()
  if not root or #files == 0 then
    vim.notify('No Claude-edited files to list', vim.log.levels.INFO)
    return
  end
  vim.ui.select(files, { prompt = 'Claude-edited files' }, function(choice)
    if not choice then return end
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. choice))
  end)
end

function M.next_diff_file()
  local root, files = project_files_with_diffs()
  if not root or #files == 0 then
    vim.notify('No Claude-edited files', vim.log.levels.INFO)
    return
  end
  local cur = current_relative_path(root)
  local idx = 0
  for i, f in ipairs(files) do if f == cur then idx = i break end end
  local next_idx = (idx % #files) + 1
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. files[next_idx]))
end

function M.prev_diff_file()
  local root, files = project_files_with_diffs()
  if not root or #files == 0 then
    vim.notify('No Claude-edited files', vim.log.levels.INFO)
    return
  end
  local cur = current_relative_path(root)
  local idx = 1
  for i, f in ipairs(files) do if f == cur then idx = i break end end
  local prev_idx = (idx - 2) % #files + 1
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. files[prev_idx]))
end

return M
