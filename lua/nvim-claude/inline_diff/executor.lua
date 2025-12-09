-- Executor for inline diff actions and redraws (renamed from ui.lua)

local M = {}

local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'
local render = require 'nvim-claude.inline_diff.render'
local utils = require 'nvim-claude.utils'
local project_state = require 'nvim-claude.project-state'
local nav = require 'nvim-claude.inline_diff.navigation'
local hunks_mod = require 'nvim-claude.inline_diff.hunks'

-- In-memory diff state per buffer (UI scope only)
local active_diffs = {}

function M.has_active_diff(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return active_diffs[bufnr] ~= nil
end

function M.get_diff_state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local d = active_diffs[bufnr]
  if not d then
    return nil
  end
  return { hunks = d.hunks, current_hunk = d.current_hunk }
end

function M.set_current_hunk(bufnr, idx)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if active_diffs[bufnr] then
    active_diffs[bufnr].current_hunk = idx
  end
end

local function set_buffer_content(bufnr, content)
  content = content or ''
  local lines = {}
  if content ~= '' then
    lines = vim.split(content, '\n', { plain = true })
    if lines[#lines] == '' then
      table.remove(lines)
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

function M.run_action(action)
  if not action or not action.type then
    return
  end
  if action.type == 'baseline_update_file' then
    local git_root = action.git_root or utils.get_project_root()
    local ref = baseline.get_baseline_ref(git_root)
    if not ref then
      return
    end
    baseline.update_baseline_with_content(git_root, action.relative_path, action.new_content or '', ref)
  elseif action.type == 'buffer_set_content' then
    set_buffer_content(action.bufnr, action.content)
  elseif action.type == 'buffer_write' then
    if action.bufnr and vim.api.nvim_buf_is_valid(action.bufnr) then
      vim.api.nvim_buf_call(action.bufnr, function()
        vim.cmd 'write!'
      end)
    end
  elseif action.type == 'buffer_reload' then
    if action.bufnr and vim.api.nvim_buf_is_valid(action.bufnr) then
      vim.api.nvim_buf_call(action.bufnr, function()
        vim.cmd 'edit!'
      end)
    end
  elseif action.type == 'file_delete' then
    if action.path and action.path ~= '' then
      pcall(os.remove, action.path)
    end
  elseif action.type == 'buffer_close' then
    if action.bufnr and vim.api.nvim_buf_is_valid(action.bufnr) then
      vim.api.nvim_buf_delete(action.bufnr, { force = true })
    end
  elseif action.type == 'project_untrack_file' then
    local git_root = action.git_root or utils.get_project_root()
    if git_root and action.relative_path then
      local map = project_state.get(git_root, 'claude_edited_files') or {}
      map[action.relative_path] = nil
      project_state.set(git_root, 'claude_edited_files', map)
    end
  elseif action.type == 'worktree_apply_reverse_patch' then
    local git_root = action.git_root or utils.get_project_root()
    local patch_file = vim.fn.tempname() .. '.patch'
    utils.write_file(patch_file, action.patch or '')
    utils.exec(string.format('cd "%s" && git apply --reverse --verbose "%s" 2>&1', git_root, patch_file))
    vim.fn.delete(patch_file)
  elseif action.type == 'baseline_remove_file' then
    local git_root = action.git_root or utils.get_project_root()
    local ref = git_root and baseline.get_baseline_ref(git_root) or nil
    if git_root and ref and action.relative_path then
      baseline.remove_from_baseline(git_root, action.relative_path, ref)
    end
  end
end

function M.run_actions(actions)
  for _, a in ipairs(actions or {}) do
    M.run_action(a)
  end
end

function M.recompute_and_render(bufnr)
  local logger = require 'nvim-claude.logger'
  logger.debug('inline_diff', 'recomputing inline diff')
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  logger.debug('inline_diff', 'buffer was valid')
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local git_root = utils.get_project_root_for_file(file_path)
  local ref = git_root and baseline.get_baseline_ref(git_root) or nil
  if not ref then
    return
  end
  local logger = require 'nvim-claude.logger'
  logger.debug('inline_diff', 'ref was valid', {
    git_ref = ref,
  })
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  local base_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, ref, relative_path)
  local base_content, err = utils.exec(base_cmd)
  if err or not base_content or base_content:match '^fatal:' or base_content:match '^error:' then
    base_content = ''
  end
  local current_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  logger.debug('inline_diff', 'diff inputs', {
    file_path = file_path,
    git_root = git_root,
    git_ref = ref,
    base_len = #(base_content or ''),
    current_len = #(current_content or ''),
    base_sha1 = vim.fn.sha256(base_content or ''),
    current_sha1 = vim.fn.sha256(current_content or ''),
    base_content = base_content,
    current_content = current_content,
  })
  local d = diffmod.compute_diff(base_content, current_content)
  if not d or not d.hunks or #d.hunks == 0 then
    -- No more hunks: clear state and visuals
    active_diffs[bufnr] = nil
    local ns_id = vim.api.nvim_create_namespace 'nvim_claude_inline_diff'
    if vim.api.nvim_buf_is_valid(bufnr) then
      logger.debug('inline_diff', 'no diffs, clearing')
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  else
    active_diffs[bufnr] = { hunks = d.hunks, current_hunk = 1 }
    logger.debug('inline_diff', 'refreshing!')
    render.apply_diff_visualization(bufnr, active_diffs[bufnr])
  end
  logger.debug('inline_diff', 'done')
  return d
end

function M.apply_plan_and_redraw(bufnr, plan)
  if not plan or plan.status == 'error' then
    return nil
  end
  M.run_actions(plan.actions)
  return M.recompute_and_render(bufnr)
end

function M.close_inline_diff(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  active_diffs[bufnr] = nil
  local ns_id = vim.api.nvim_create_namespace 'nvim_claude_inline_diff'
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

function M.clear_all_visuals()
  for b, _ in pairs(active_diffs) do
    M.close_inline_diff(b)
  end
end

-- Show diff for a buffer from explicit old/new content
function M.show_inline_diff(bufnr, old_content, new_content, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local d = diffmod.compute_diff(old_content or '', new_content or '')
  if not d or not d.hunks or #d.hunks == 0 then
    return
  end
  active_diffs[bufnr] = { hunks = d.hunks, current_hunk = 1 }
  render.apply_diff_visualization(bufnr, active_diffs[bufnr])
  -- Buffer-local keymaps for hunk navigation/actions
  pcall(vim.keymap.set, 'n', ']h', function()
    nav.next_hunk(bufnr, active_diffs[bufnr])
  end, { buffer = bufnr, silent = true })
  pcall(vim.keymap.set, 'n', '[h', function()
    nav.prev_hunk(bufnr, active_diffs[bufnr])
  end, { buffer = bufnr, silent = true })
  pcall(vim.keymap.set, 'n', '<leader>ia', function()
    local plan = hunks_mod.accept_current_hunk(bufnr)
    if not plan or plan.status == 'error' then
      local reason = (plan and plan.info and plan.info.reason) or 'accept_failed'
      vim.notify('Claude: failed to accept hunk (' .. tostring(reason) .. ')', vim.log.levels.ERROR)
      return
    end
    M.apply_plan_and_redraw(bufnr, plan)
  end, { buffer = bufnr, silent = true, desc = 'Claude: accept current hunk' })
  pcall(vim.keymap.set, 'n', '<leader>ir', function()
    local plan = hunks_mod.reject_current_hunk(bufnr)
    if not plan or plan.status == 'error' then
      local reason = (plan and plan.info and plan.info.reason) or 'reject_failed'
      vim.notify('Claude: failed to reject hunk (' .. tostring(reason) .. ')', vim.log.levels.ERROR)
      return
    end
    M.apply_plan_and_redraw(bufnr, plan)
  end, { buffer = bufnr, silent = true, desc = 'Claude: reject current hunk' })
  pcall(vim.keymap.set, 'n', '<leader>iA', function()
    local plan = hunks_mod.accept_all_hunks_in_file(bufnr)
    M.apply_plan_and_redraw(bufnr, plan)
  end, { buffer = bufnr, silent = true, desc = 'Claude: accept all hunks in file' })
  pcall(vim.keymap.set, 'n', '<leader>iR', function()
    local plan = hunks_mod.reject_all_hunks_in_file(bufnr)
    M.apply_plan_and_redraw(bufnr, plan)
  end, { buffer = bufnr, silent = true, desc = 'Claude: reject all hunks in file' })

  if not opts.preserve_cursor then
    nav.jump_to_hunk(bufnr, active_diffs[bufnr], 1, true)
  end
end

return M
