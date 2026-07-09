local M = {}

local utils = require 'nvim-claude.utils'
local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'

local function action(action_type, fields)
  return vim.tbl_extend('force', { type = action_type }, fields or {})
end

local function content_lines(content)
  if not content or content == '' then return {} end
  local lines = vim.split(content, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function hunk_side_lines(hunk, old_side)
  local result = {}
  for _, line in ipairs(hunk.lines or {}) do
    local prefix = line:sub(1, 1)
    if prefix == ' ' or (old_side and prefix == '-') or (not old_side and prefix == '+') then
      table.insert(result, line:sub(2))
    end
  end
  return result
end

local function ranges_equal(lines, start_line, expected)
  if #expected == 0 then return true end
  if start_line < 1 or start_line + #expected - 1 > #lines then return false end
  for i, expected_line in ipairs(expected) do
    if lines[start_line + i - 1] ~= expected_line then return false end
  end
  return true
end

local function apply_hunk_to_content(content, hunk, reverse)
  local lines = content_lines(content)
  local target_start = reverse and hunk.new_start or hunk.old_start
  local target_count = reverse and hunk.new_count or hunk.old_count
  local expected = hunk_side_lines(hunk, not reverse)
  local replacement = hunk_side_lines(hunk, reverse)

  if target_count ~= #expected then return nil, 'invalid_hunk' end
  if target_count > 0 and not ranges_equal(lines, target_start, expected) then
    return nil, 'hunk_context_changed'
  end

  local before_count = target_count == 0 and target_start or target_start - 1
  if before_count < 0 or before_count > #lines then return nil, 'invalid_hunk_range' end

  local result = {}
  for i = 1, before_count do table.insert(result, lines[i]) end
  vim.list_extend(result, replacement)
  for i = before_count + target_count + 1, #lines do table.insert(result, lines[i]) end
  if #result == 0 then return '' end
  return table.concat(result, '\n') .. '\n'
end

function M.generate_hunk_patch(hunk, file_path)
  local patch_lines = {
    string.format('--- a/%s', file_path),
    string.format('+++ b/%s', file_path),
    hunk.header,
  }
  vim.list_extend(patch_lines, hunk.lines or {})
  table.insert(patch_lines, '')
  return table.concat(patch_lines, '\n')
end

function M.apply_patch_to_content(content, patch, reverse)
  local hunks = diffmod.parse_unified_diff(patch)
  if #hunks ~= 1 then return nil end
  return apply_hunk_to_content(content, hunks[1], reverse)
end

local function get_file_context(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil, 'invalid_buffer'
  end
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local git_root = utils.get_project_root_for_file(file_path)
  if not git_root then return nil, 'no_root' end
  local ref = baseline.get_baseline_ref(git_root)
  if not ref then return nil, 'no_baseline' end
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  local base, read_err = baseline.read_file(git_root, relative_path, ref)
  if not base then return nil, 'baseline_read_failed: ' .. tostring(read_err) end
  return {
    bufnr = bufnr,
    file_path = file_path,
    git_root = git_root,
    relative_path = relative_path,
    ref = ref,
    baseline = base,
    current_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n'),
  }
end

local function error_plan(reason, bufnr, file_path)
  return { status = 'error', actions = {}, info = { reason = reason, bufnr = bufnr, file = file_path } }
end

function M.accept_hunk_for_file(bufnr, hunk)
  local context, context_err = get_file_context(bufnr)
  if not context then return error_plan(context_err, bufnr) end

  local updated_content, patch_err = apply_hunk_to_content(context.baseline.content, hunk, false)
  if updated_content == nil then return error_plan(patch_err or 'patch_failed', bufnr, context.file_path) end

  local next_diff, diff_err = diffmod.compute_diff(updated_content, context.current_content, {
    old_exists = true,
    new_exists = true,
  })
  if not next_diff then return error_plan('diff_failed: ' .. tostring(diff_err), bufnr, context.file_path) end

  local actions = {
    action('baseline_update_file', {
      git_root = context.git_root,
      relative_path = context.relative_path,
      new_content = updated_content,
    }),
  }
  if #next_diff.hunks == 0 then
    table.insert(actions, action('project_untrack_file', {
      git_root = context.git_root,
      relative_path = context.relative_path,
    }))
  end
  return {
    status = 'ok',
    actions = actions,
    next_diff = next_diff,
    info = { bufnr = bufnr, file = context.file_path },
  }
end

function M.accept_current_hunk(bufnr)
  local exec = require 'nvim-claude.inline_diff.executor'
  local data = exec.get_diff_state(bufnr)
  if not data then return error_plan('no_diff_data', bufnr) end
  local hunk = data.hunks[data.current_hunk]
  if not hunk then return error_plan('no_hunk', bufnr) end
  return M.accept_hunk_for_file(bufnr, hunk)
end

function M.reject_current_hunk(bufnr)
  local exec = require 'nvim-claude.inline_diff.executor'
  local data = exec.get_diff_state(bufnr)
  if not data then return error_plan('no_diff_data', bufnr) end
  local hunk = data.hunks[data.current_hunk]
  if not hunk then return error_plan('no_hunk', bufnr) end

  local context, context_err = get_file_context(bufnr)
  if not context then return error_plan(context_err, bufnr) end
  local new_content, patch_err = apply_hunk_to_content(context.current_content, hunk, true)
  if new_content == nil then return error_plan(patch_err or 'reverse_patch_failed', bufnr, context.file_path) end

  local actions = {}
  local next_diff
  if not context.baseline.exists and new_content == '' then
    actions = {
      action('buffer_close', { bufnr = bufnr }),
      action('file_delete', { path = context.file_path }),
      action('project_untrack_file', {
        git_root = context.git_root,
        relative_path = context.relative_path,
      }),
    }
    next_diff = { hunks = {} }
  else
    next_diff, patch_err = diffmod.compute_diff(context.baseline.content, new_content, {
      old_exists = context.baseline.exists,
      new_exists = true,
    })
    if not next_diff then return error_plan('diff_failed: ' .. tostring(patch_err), bufnr, context.file_path) end
    actions = {
      action('buffer_set_content', { bufnr = bufnr, content = new_content }),
      action('buffer_write', { bufnr = bufnr }),
    }
    if #next_diff.hunks == 0 then
      table.insert(actions, action('project_untrack_file', {
        git_root = context.git_root,
        relative_path = context.relative_path,
      }))
    end
  end

  return {
    status = 'ok',
    actions = actions,
    next_diff = next_diff,
    info = { bufnr = bufnr, file = context.file_path },
  }
end

function M.accept_all_hunks_in_file(bufnr)
  local context, context_err = get_file_context(bufnr)
  if not context then return error_plan(context_err, bufnr) end
  local content = context.current_content
  if content ~= '' and not content:match '\n$' then content = content .. '\n' end
  return {
    status = 'ok',
    actions = {
      action('baseline_update_file', {
        git_root = context.git_root,
        relative_path = context.relative_path,
        new_content = content,
      }),
      action('project_untrack_file', {
        git_root = context.git_root,
        relative_path = context.relative_path,
      }),
    },
    next_diff = { hunks = {} },
    info = { bufnr = bufnr, file = context.file_path },
  }
end

function M.reject_all_hunks_in_file(bufnr)
  local context, context_err = get_file_context(bufnr)
  if not context then return error_plan(context_err, bufnr) end
  local actions
  if context.baseline.exists then
    actions = {
      action('buffer_set_content', { bufnr = bufnr, content = context.baseline.content }),
      action('buffer_write', { bufnr = bufnr }),
    }
  else
    actions = {
      action('buffer_close', { bufnr = bufnr }),
      action('file_delete', { path = context.file_path }),
    }
  end
  table.insert(actions, action('project_untrack_file', {
    git_root = context.git_root,
    relative_path = context.relative_path,
  }))
  return {
    status = 'ok',
    actions = actions,
    next_diff = { hunks = {} },
    info = { bufnr = bufnr, file = context.file_path },
  }
end

local function aggregate_plans(active_diffs, build_plan)
  local actions = {}
  for bufnr, data in pairs(active_diffs or {}) do
    if data and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local plan = build_plan(bufnr)
      if not plan or plan.status == 'error' then return plan or error_plan('plan_failed', bufnr) end
      vim.list_extend(actions, plan.actions or {})
    end
  end
  return { status = 'ok', actions = actions }
end

function M.accept_all_hunks_in_all_files(active_diffs)
  return aggregate_plans(active_diffs, M.accept_all_hunks_in_file)
end

function M.reject_all_hunks_in_all_files(active_diffs)
  return aggregate_plans(active_diffs, M.reject_all_hunks_in_file)
end

local navigation = require 'nvim-claude.inline_diff.navigation'

local function find_loaded_buffer(path)
  local target = vim.fn.fnamemodify(path, ':p')
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and vim.fn.fnamemodify(name, ':p') == target then return bufnr end
    end
  end
  return nil
end

function M.accept_all_files()
  local root, items = navigation.get_edited_items()
  if not root or #items == 0 then return { ok = false, reason = 'no_items' } end
  local ref = baseline.get_baseline_ref(root)
  if not ref then return { ok = false, reason = 'no_baseline' } end

  local changes = {}
  local paths = {}
  for _, item in ipairs(items) do
    table.insert(paths, item.rel)
    if item.deleted then
      table.insert(changes, { relative_path = item.rel, exists = false })
    else
      local content = utils.read_file(root .. '/' .. item.rel)
      if content == nil then return { ok = false, reason = 'file_read_failed', file = item.rel } end
      table.insert(changes, { relative_path = item.rel, exists = true, content = content })
    end
  end
  return {
    ok = true,
    status = 'ok',
    root = root,
    items = items,
    actions = {
      action('baseline_apply_changes', { git_root = root, ref = ref, changes = changes }),
      action('project_untrack_files', { git_root = root, relative_paths = paths }),
    },
  }
end

function M.reject_all_files()
  local root, items = navigation.get_edited_items()
  if not root or #items == 0 then return { ok = false, reason = 'no_items' } end
  local ref = baseline.get_baseline_ref(root)
  if not ref then return { ok = false, reason = 'no_baseline' } end

  local actions = {}
  local paths = {}
  for _, item in ipairs(items) do
    local full_path = root .. '/' .. item.rel
    local base, read_err = baseline.read_file(root, item.rel, ref)
    if not base then
      return { ok = false, reason = 'baseline_read_failed', file = item.rel, error = read_err }
    end
    local bufnr = find_loaded_buffer(full_path)
    if base.exists then
      if bufnr then
        table.insert(actions, action('buffer_set_content', { bufnr = bufnr, content = base.content }))
        table.insert(actions, action('buffer_write', { bufnr = bufnr }))
      else
        table.insert(actions, action('file_write', { path = full_path, content = base.content }))
      end
    else
      if bufnr then table.insert(actions, action('buffer_close', { bufnr = bufnr })) end
      table.insert(actions, action('file_delete', { path = full_path }))
    end
    table.insert(paths, item.rel)
  end
  table.insert(actions, action('project_untrack_files', {
    git_root = root,
    relative_paths = paths,
  }))
  return { ok = true, status = 'ok', root = root, items = items, actions = actions }
end

return M
