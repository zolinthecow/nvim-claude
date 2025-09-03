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

-- Private state: active diffs per buffer
local active_diffs = {}
-- Facade-local helper to detect deleted-file scratch buffers
local function parse_deleted_rel(bufname)
  if type(bufname) ~= 'string' then
    return nil
  end
  return bufname:match '^%[deleted%]%s+(.+)$'
end

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
function M.create_baseline(message)
  return baseline.create_baseline(message)
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
  return active_diffs[bufnr] ~= nil
end
function M.get_diff_state(bufnr)
  local d = active_diffs[bufnr]
  if not d then
    return nil
  end
  return { hunks = d.hunks, current_hunk = d.current_hunk }
end
function M.set_current_hunk(bufnr, idx)
  if active_diffs[bufnr] then
    active_diffs[bufnr].current_hunk = idx
  end
end
function M.compute_diff(old_text, new_text)
  return diffmod.compute_diff(old_text, new_text)
end

-- --- Visualization entry points ---
function M.show_inline_diff(bufnr, old_content, new_content, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local d = diffmod.compute_diff(old_content or '', new_content or '')
  if not d or not d.hunks or #d.hunks == 0 then
    return
  end
  active_diffs[bufnr] = { hunks = d.hunks, current_hunk = 1 }
  render.apply_diff_visualization(bufnr, active_diffs[bufnr])
  -- Buffer-local hunk navigation
  pcall(vim.keymap.set, 'n', ']h', function()
    M.next_hunk(bufnr)
  end, { buffer = bufnr, silent = true })
  pcall(vim.keymap.set, 'n', '[h', function()
    M.prev_hunk(bufnr)
  end, { buffer = bufnr, silent = true })
  -- Buffer-local hunk actions
  pcall(vim.keymap.set, 'n', '<leader>ia', function()
    M.accept_current_hunk(bufnr)
  end, { buffer = bufnr, silent = true, desc = 'Claude: accept current hunk' })
  pcall(vim.keymap.set, 'n', '<leader>ir', function()
    M.reject_current_hunk(bufnr)
  end, { buffer = bufnr, silent = true, desc = 'Claude: reject current hunk' })
  pcall(vim.keymap.set, 'n', '<leader>iA', function()
    M.accept_all_hunks(bufnr)
  end, { buffer = bufnr, silent = true, desc = 'Claude: accept all hunks in file' })
  pcall(vim.keymap.set, 'n', '<leader>iR', function()
    M.reject_all_hunks(bufnr)
  end, { buffer = bufnr, silent = true, desc = 'Claude: reject all hunks in file' })
  if not opts.preserve_cursor then
    nav.jump_to_hunk(bufnr, active_diffs[bufnr], 1, true)
  end
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
  if not d then
    return
  end
  nav.jump_to_hunk(bufnr, d, idx, silent)
end
function M.next_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local d = active_diffs[bufnr]
  if not d then
    return
  end
  nav.next_hunk(bufnr, d)
end
function M.prev_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local d = active_diffs[bufnr]
  if not d then
    return
  end
  nav.prev_hunk(bufnr, d)
end

-- --- Accept / Reject operations ---
local function apply_and_redraw(bufnr, plan)
  return exec.apply_plan_and_redraw(bufnr, plan, active_diffs)
end

function M.accept_current_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.accept_current_hunk(bufnr, active_diffs)
  if not plan or plan.status == 'error' then
    local reason = (plan and plan.info and plan.info.reason) or 'accept_failed'
    vim.notify('Claude: failed to accept hunk (' .. tostring(reason) .. ')', vim.log.levels.ERROR)
    return nil
  end
  return apply_and_redraw(bufnr, plan)
end

function M.reject_current_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local plan = hunks.reject_current_hunk(bufnr, active_diffs)
  if not plan or plan.status == 'error' then
    local reason = (plan and plan.info and plan.info.reason) or 'reject_failed'
    vim.notify('Claude: failed to reject hunk (' .. tostring(reason) .. ')', vim.log.levels.ERROR)
    return nil
  end
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
  local result = hunks.accept_all_files()
  if not result or result.ok == false then
    vim.notify('No Claude-edited files to accept', vim.log.levels.INFO)
    return
  end
  -- Clear visuals in any buffers that had inline diffs
  for bufnr, _ in pairs(active_diffs) do
    M.close_inline_diff(bufnr)
  end
  -- If current buffer is a deleted-file scratch view, close it
  local cur = vim.api.nvim_get_current_buf()
  local rel = parse_deleted_rel(vim.api.nvim_buf_get_name(cur))
  if rel then
    pcall(vim.api.nvim_buf_delete, cur, { force = true })
  end
  vim.notify('Accepted all Claude-edited files', vim.log.levels.INFO)
end

function M.reject_all_files()
  local result = hunks.reject_all_files()
  if not result or result.ok == false then
    vim.notify('No Claude-edited files to reject', vim.log.levels.INFO)
    return
  end
  local root = result.root
  -- Clear visuals
  for bufnr, _ in pairs(active_diffs) do
    M.close_inline_diff(bufnr)
  end
  -- If current buffer is a deleted-file scratch view, jump to the restored file
  local cur = vim.api.nvim_get_current_buf()
  local rel = parse_deleted_rel(vim.api.nvim_buf_get_name(cur))
  if rel and root then
    local full = root .. '/' .. rel
    pcall(vim.api.nvim_buf_delete, cur, { force = true })
    vim.schedule(function()
      vim.cmd('edit ' .. vim.fn.fnameescape(full))
    end)
  end
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

return M
