local M = {}

local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'
local render = require 'nvim-claude.inline_diff.render'
local utils = require 'nvim-claude.utils'
local review_state = require 'nvim-claude.review_state'
local nav = require 'nvim-claude.inline_diff.navigation'
local hunks_mod = require 'nvim-claude.inline_diff.hunks'

local namespace = vim.api.nvim_create_namespace 'nvim_claude_inline_diff'
local active_diffs = {}

local cleanup_group = vim.api.nvim_create_augroup('NvimClaudeInlineDiffState', { clear = true })
vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = cleanup_group,
  callback = function(args) active_diffs[args.buf] = nil end,
})

function M.has_active_diff(bufnr)
  return active_diffs[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

function M.get_diff_state(bufnr)
  local state = active_diffs[bufnr or vim.api.nvim_get_current_buf()]
  if not state then return nil end
  return { hunks = state.hunks, current_hunk = state.current_hunk }
end

function M.set_current_hunk(bufnr, idx)
  local state = active_diffs[bufnr or vim.api.nvim_get_current_buf()]
  if not state or #state.hunks == 0 then return false end
  state.current_hunk = math.max(1, math.min(tonumber(idx) or 1, #state.hunks))
  return true
end

local function result_ok()
  return { ok = true }
end

local function result_error(action, err)
  return { ok = false, action = action, error = tostring(err or 'action failed') }
end

local function set_buffer_content(bufnr, content)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return false, 'buffer is not loaded'
  end
  local lines = {}
  if content and content ~= '' then
    lines = vim.split(content, '\n', { plain = true })
    if lines[#lines] == '' then table.remove(lines) end
  end
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  return ok, err
end

function M.run_action(action)
  if not action or not action.type then return result_error(action, 'invalid action') end

  if action.type == 'baseline_update_file' then
    local git_root = action.git_root or utils.get_project_root()
    local ref = action.ref or baseline.get_baseline_ref(git_root)
    if not ref then return result_error(action, 'no baseline') end
    local ok, err = baseline.update_baseline_with_content(
      git_root,
      action.relative_path,
      action.new_content or '',
      ref
    )
    if not ok then return result_error(action, err) end
  elseif action.type == 'baseline_apply_changes' then
    local ok, err = baseline.apply_changes(action.git_root, action.changes, action.ref)
    if not ok then return result_error(action, err) end
  elseif action.type == 'baseline_remove_file' then
    local git_root = action.git_root or utils.get_project_root()
    local ref = action.ref or baseline.get_baseline_ref(git_root)
    local ok, err = baseline.remove_from_baseline(git_root, action.relative_path, ref)
    if not ok then return result_error(action, err) end
  elseif action.type == 'buffer_set_content' then
    local ok, err = set_buffer_content(action.bufnr, action.content)
    if not ok then return result_error(action, err) end
  elseif action.type == 'buffer_write' then
    if not (action.bufnr and vim.api.nvim_buf_is_valid(action.bufnr)) then
      return result_error(action, 'invalid buffer')
    end
    local ok, err = pcall(vim.api.nvim_buf_call, action.bufnr, function()
      vim.cmd 'silent write!'
    end)
    if not ok then return result_error(action, err) end
  elseif action.type == 'buffer_reload' then
    if not (action.bufnr and vim.api.nvim_buf_is_valid(action.bufnr)) then
      return result_error(action, 'invalid buffer')
    end
    local ok, err = pcall(vim.api.nvim_buf_call, action.bufnr, function()
      vim.cmd 'silent edit!'
    end)
    if not ok then return result_error(action, err) end
  elseif action.type == 'buffer_close' then
    if action.bufnr and vim.api.nvim_buf_is_valid(action.bufnr) then
      local ok, err = pcall(vim.api.nvim_buf_delete, action.bufnr, { force = true })
      if not ok then return result_error(action, err) end
    end
    if action.bufnr then active_diffs[action.bufnr] = nil end
  elseif action.type == 'file_write' then
    if not action.path or action.path == '' then return result_error(action, 'missing file path') end
    if not utils.ensure_dir(vim.fn.fnamemodify(action.path, ':h')) then
      return result_error(action, 'failed to create parent directory')
    end
    if not utils.write_file(action.path, action.content or '') then
      return result_error(action, 'failed to write file')
    end
  elseif action.type == 'file_delete' then
    if not action.path or action.path == '' then return result_error(action, 'missing file path') end
    if vim.loop.fs_stat(action.path) then
      local ok, err = os.remove(action.path)
      if not ok then return result_error(action, err) end
    end
  elseif action.type == 'project_untrack_file' then
    local git_root = action.git_root or utils.get_project_root()
    if not review_state.remove_edited_file(git_root, action.relative_path) then
      return result_error(action, 'failed to update review state')
    end
  elseif action.type == 'project_untrack_files' then
    local git_root = action.git_root or utils.get_project_root()
    if not review_state.remove_edited_files(git_root, action.relative_paths) then
      return result_error(action, 'failed to update review state')
    end
  else
    return result_error(action, 'unknown action type: ' .. tostring(action.type))
  end

  return result_ok()
end

function M.run_actions(actions)
  for index, action in ipairs(actions or {}) do
    local result = M.run_action(action)
    if not result.ok then
      result.index = index
      result.completed = index - 1
      return result
    end
  end
  return { ok = true, completed = #(actions or {}) }
end

local function nearest_hunk(hunks, anchor)
  if not anchor then return 1 end
  local nearest_idx = 1
  local nearest_distance = math.huge
  for idx, hunk in ipairs(hunks) do
    local line = math.max(1, hunk.new_start or 1)
    local distance = math.abs(line - anchor)
    if distance < nearest_distance then
      nearest_idx = idx
      nearest_distance = distance
    end
  end
  return nearest_idx
end

local function render_computed_diff(bufnr, computed)
  local previous = active_diffs[bufnr]
  local anchor
  if previous and previous.hunks[previous.current_hunk] then
    anchor = math.max(1, previous.hunks[previous.current_hunk].new_start or 1)
  end

  if not computed or not computed.hunks or #computed.hunks == 0 then
    active_diffs[bufnr] = nil
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    end
    return computed
  end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return computed end

  active_diffs[bufnr] = {
    hunks = computed.hunks,
    current_hunk = nearest_hunk(computed.hunks, anchor),
  }
  render.apply_diff_visualization(bufnr, active_diffs[bufnr])
  return computed
end

function M.recompute_and_render(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return nil, 'invalid buffer' end
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local git_root = utils.get_project_root_for_file(file_path)
  local ref = git_root and baseline.get_baseline_ref(git_root) or nil
  if not ref then return nil, 'no baseline' end
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  local base, read_err = baseline.read_file(git_root, relative_path, ref)
  if not base then return nil, read_err end

  local current_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local computed, diff_err = diffmod.compute_diff(base.content, current_content, {
    old_exists = base.exists,
    new_exists = vim.fn.filereadable(file_path) == 1,
  })
  if not computed then return nil, diff_err end
  return render_computed_diff(bufnr, computed)
end

function M.apply_plan_and_redraw(bufnr, plan)
  if not plan or plan.status == 'error' then
    return nil, { ok = false, error = plan and plan.info and plan.info.reason or 'invalid plan' }
  end
  local result = M.run_actions(plan.actions)
  if not result.ok then
    require('nvim-claude.logger').error('inline_diff', 'Failed to apply review action', {
      action = result.action and result.action.type,
      error = result.error,
    })
    vim.notify('Claude: review action failed (' .. result.error .. ')', vim.log.levels.ERROR)
    return nil, result
  end
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    active_diffs[bufnr] = nil
    return nil, result
  end
  if plan.next_diff then return render_computed_diff(bufnr, plan.next_diff), result end
  return M.recompute_and_render(bufnr), result
end

function M.close_inline_diff(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  active_diffs[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

function M.clear_all_visuals()
  local buffers = vim.tbl_keys(active_diffs)
  for _, bufnr in ipairs(buffers) do M.close_inline_diff(bufnr) end
end

function M.jump_to_hunk(bufnr, idx, silent)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = active_diffs[bufnr]
  if not state then return end
  return nav.jump_to_hunk(bufnr, state, idx, silent)
end

function M.next_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = active_diffs[bufnr]
  if not state then return end
  return nav.next_hunk(bufnr, state)
end

function M.prev_hunk(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = active_diffs[bufnr]
  if not state then return end
  return nav.prev_hunk(bufnr, state)
end

function M.show_inline_diff(bufnr, old_content, new_content, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local computed = opts.diff
  local diff_err
  if not computed then
    computed, diff_err = diffmod.compute_diff(old_content or '', new_content or '', {
      old_exists = opts.old_exists,
      new_exists = opts.new_exists,
    })
  end
  if not computed then return nil, diff_err end
  render_computed_diff(bufnr, computed)
  if #computed.hunks == 0 then return computed end

  pcall(vim.keymap.set, 'n', ']h', function() M.next_hunk(bufnr) end, { buffer = bufnr, silent = true })
  pcall(vim.keymap.set, 'n', '[h', function() M.prev_hunk(bufnr) end, { buffer = bufnr, silent = true })
  pcall(vim.keymap.set, 'n', '<leader>ia', function()
    local plan = hunks_mod.accept_current_hunk(bufnr)
    M.apply_plan_and_redraw(bufnr, plan)
  end, { buffer = bufnr, silent = true, desc = 'Claude: accept current hunk' })
  pcall(vim.keymap.set, 'n', '<leader>ir', function()
    local plan = hunks_mod.reject_current_hunk(bufnr)
    M.apply_plan_and_redraw(bufnr, plan)
  end, { buffer = bufnr, silent = true, desc = 'Claude: reject current hunk' })
  pcall(vim.keymap.set, 'n', '<leader>iA', function()
    M.apply_plan_and_redraw(bufnr, hunks_mod.accept_all_hunks_in_file(bufnr))
  end, { buffer = bufnr, silent = true, desc = 'Claude: accept all hunks in file' })
  pcall(vim.keymap.set, 'n', '<leader>iR', function()
    M.apply_plan_and_redraw(bufnr, hunks_mod.reject_all_hunks_in_file(bufnr))
  end, { buffer = bufnr, silent = true, desc = 'Claude: reject all hunks in file' })

  if not opts.preserve_cursor then M.jump_to_hunk(bufnr, 1, true) end
  return computed
end

return M
