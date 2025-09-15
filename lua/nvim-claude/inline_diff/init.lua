-- Facade for inline diff functionality (modular API)
-- NOTE (tests): This façade is covered by E2E tests.
-- Any interface or behavior changes here should be reflected in tests/e2e_spec.lua.

local M = {}

local baseline = require 'nvim-claude.inline_diff.baseline'
local exec = require 'nvim-claude.inline_diff.executor'
local nav = require 'nvim-claude.inline_diff.navigation'
local persist = require 'nvim-claude.inline_diff.persistence'
local hunks = require 'nvim-claude.inline_diff.hunks'
local utils = require 'nvim-claude.utils'

-- Facade: delegates to internal modules; contains no business logic

-- --- Baseline API ---
function M.get_baseline_ref(git_root)
  return baseline.get_baseline_ref(git_root)
end
function M.set_baseline_ref(git_root, ref)
  return baseline.set_baseline_ref(git_root, ref)
end
function M.clear_baseline_ref(git_root)
  return baseline.clear_baseline_ref(git_root)
end
function M.create_baseline(message, git_root)
  return baseline.create_baseline(message, git_root)
end

-- Update a single file's content inside the current baseline commit
-- Returns true on success
function M.update_baseline_file(git_root, relative_path, new_content)
  git_root = git_root or utils.get_project_root()
  if not git_root then
    return false
  end
  local ref = baseline.get_baseline_ref(git_root)
  if not ref then
    return false
  end
  return baseline.update_baseline_with_content(git_root, relative_path, new_content or '', ref)
end

-- --- Diff state helpers (read-only) ---
function M.has_active_diff(bufnr)
  return exec.has_active_diff(bufnr)
end
function M.get_diff_state(bufnr)
  return exec.get_diff_state(bufnr)
end
function M.set_current_hunk(bufnr, idx)
  return exec.set_current_hunk(bufnr, idx)
end

-- --- Visualization entry points ---
function M.show_inline_diff(bufnr, old_content, new_content, opts)
  return exec.show_inline_diff(bufnr, old_content, new_content, opts)
end

function M.refresh_inline_diff(bufnr)
  return exec.recompute_and_render(bufnr or vim.api.nvim_get_current_buf())
end

function M.close_inline_diff(bufnr)
  return exec.close_inline_diff(bufnr)
end

-- --- Navigation ---
function M.jump_to_hunk(bufnr, idx, silent)
  local d = exec.get_diff_state(bufnr)
  if not d then
    return
  end
  nav.jump_to_hunk(bufnr or vim.api.nvim_get_current_buf(), d, idx, silent)
end
function M.next_hunk(bufnr)
  local d = exec.get_diff_state(bufnr)
  if not d then
    return
  end
  nav.next_hunk(bufnr or vim.api.nvim_get_current_buf(), d)
end
function M.prev_hunk(bufnr)
  local d = exec.get_diff_state(bufnr)
  if not d then
    return
  end
  nav.prev_hunk(bufnr or vim.api.nvim_get_current_buf(), d)
end

-- --- Accept / Reject operations ---
local function apply_and_redraw(bufnr, plan)
  return exec.apply_plan_and_redraw(bufnr or vim.api.nvim_get_current_buf(), plan)
end

function M.accept_current_hunk(bufnr)
  local plan = hunks.accept_current_hunk(bufnr or vim.api.nvim_get_current_buf())
  if not plan or plan.status == 'error' then
    local reason = (plan and plan.info and plan.info.reason) or 'accept_failed'
    vim.notify('Claude: failed to accept hunk (' .. tostring(reason) .. ')', vim.log.levels.ERROR)
    return nil
  end
  return apply_and_redraw(bufnr, plan)
end

function M.reject_current_hunk(bufnr)
  local plan = hunks.reject_current_hunk(bufnr or vim.api.nvim_get_current_buf())
  if not plan or plan.status == 'error' then
    local reason = (plan and plan.info and plan.info.reason) or 'reject_failed'
    vim.notify('Claude: failed to reject hunk (' .. tostring(reason) .. ')', vim.log.levels.ERROR)
    return nil
  end
  return apply_and_redraw(bufnr, plan)
end

function M.accept_all_hunks(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.accept_all_hunks_in_file(b)
  return apply_and_redraw(b, plan)
end

function M.reject_all_hunks(bufnr)
  local b = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.reject_all_hunks_in_file(b)
  return apply_and_redraw(b, plan)
end

function M.accept_all_files()
  local result = hunks.accept_all_files()
  if not result or result.ok == false then
    vim.notify('No Claude-edited files to accept', vim.log.levels.INFO)
    return
  end
  exec.clear_all_visuals()
  nav.close_current_deleted_view_if_any()
  vim.notify('Accepted all Claude-edited files', vim.log.levels.INFO)
end

function M.reject_all_files()
  local result = hunks.reject_all_files()
  if not result or result.ok == false then
    vim.notify('No Claude-edited files to reject', vim.log.levels.INFO)
    return
  end
  exec.clear_all_visuals()
  nav.open_restored_if_was_deleted_view(result.root)
  vim.notify('Rejected all Claude-edited files', vim.log.levels.INFO)
end

-- Clear persistence state for inline diffs (project-state)
function M.clear_persistence(git_root)
  return persist.clear_state(git_root)
end

-- File navigation facade delegates
function M.list_diff_files()
  return nav.list_files()
end
function M.next_diff_file()
  return nav.next_file()
end
function M.prev_diff_file()
  return nav.prev_file()
end

-- Light re-export for internal consumers needing pure diff computation
function M.compute_diff(old_text, new_text)
  return require('nvim-claude.inline_diff.diff').compute_diff(old_text, new_text)
end

return M
