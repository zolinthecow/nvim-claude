-- Facade for inline diff functionality (modular API)

local M = {}

local utils = require 'nvim-claude.utils'
local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'
local render = require 'nvim-claude.inline_diff.render'
local hunks = require 'nvim-claude.inline_diff.hunks'
local exec = require 'nvim-claude.inline_diff.executor'
local nav = require 'nvim-claude.inline_diff.navigation'

-- Private state: active diffs per buffer
local active_diffs = {}

-- --- Baseline API ---
function M.get_baseline_ref(git_root) return baseline.get_baseline_ref(git_root) end
function M.set_baseline_ref(git_root, ref) return baseline.set_baseline_ref(git_root, ref) end
function M.clear_baseline_ref(git_root) return baseline.clear_baseline_ref(git_root) end
function M.create_baseline(message) return baseline.create_baseline(message) end

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

return M

