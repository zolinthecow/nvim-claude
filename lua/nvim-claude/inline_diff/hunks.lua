-- Hunk-level operations: generate patches, accept/reject hunks

local M = {}

local utils = require 'nvim-claude.utils'
local baseline = require 'nvim-claude.inline_diff.baseline'
local diffmod = require 'nvim-claude.inline_diff.diff'

-- Build an action descriptor for the UI/executor layer
local function action(t, fields)
  local a = { type = t }
  if fields then
    for k, v in pairs(fields) do
      a[k] = v
    end
  end
  return a
end

-- Generate a patch for a single hunk
function M.generate_hunk_patch(hunk, file_path)
  local patch_lines = {
    string.format('--- a/%s', file_path),
    string.format('+++ b/%s', file_path),
    hunk.header,
  }

  for _, line in ipairs(hunk.lines or {}) do
    table.insert(patch_lines, line)
  end

  table.insert(patch_lines, '')
  return table.concat(patch_lines, '\n')
end

-- Apply patch to content string using git apply in a temp dir
function M.apply_patch_to_content(content, patch, reverse, target_path)
  -- Create a temporary directory for patch application
  local temp_dir = '/tmp/nvim-claude-patch-' .. os.time()
  vim.fn.mkdir(temp_dir, 'p')

  local target = target_path or 'file'
  local target_dir = vim.fn.fnamemodify(target, ':h')
  if target_dir ~= '' and target_dir ~= '.' then
    vim.fn.mkdir(temp_dir .. '/' .. target_dir, 'p')
  end

  local temp_file = temp_dir .. '/' .. target
  local patch_file = temp_dir .. '/patch.patch'

  -- Ensure trailing newline for stable patching semantics
  if content ~= '' and not content:match('\n$') then content = content .. '\n' end
  if not utils.write_file(temp_file, content) then
    vim.fn.delete(temp_dir, 'rf')
    return nil
  end
  utils.write_file(patch_file, patch)

  local cmd = table.concat({
    'cd',
    vim.fn.shellescape(temp_dir),
    '&&',
    'git init -q',
    '&&',
    'git add', vim.fn.shellescape(target),
    '&&',
    ('git apply --index --reject ' .. (reverse and '--reverse ' or '')),
    vim.fn.shellescape(patch_file),
    '2>&1',
  }, ' ')

  local result, err = utils.exec(cmd)
  if err or (result and result:match 'error:') then
    vim.fn.delete(temp_dir, 'rf')
    return nil
  end

  local cat_cmd = string.format('cd %s && git show :%s 2>/dev/null', vim.fn.shellescape(temp_dir), target)
  local new_content = utils.exec(cat_cmd)

  vim.fn.delete(temp_dir, 'rf')
  return new_content
end

-- Accept a single hunk: patch the baseline commit tree for just this hunk
function M.accept_hunk_for_file(bufnr, hunk)
  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  -- Generate hunk patch using the actual relative path
  local hunk_patch = M.generate_hunk_patch(hunk, relative_path)

  -- Get current baseline
  local ref = baseline.get_baseline_ref(git_root)
  if not ref then
    return { status = 'error', actions = {}, info = { reason = 'no_baseline', bufnr = bufnr, file = file_path } }
  end

  -- Read baseline content for this file (empty if not present)
  local baseline_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, ref, relative_path)
  local baseline_content, git_err = utils.exec(baseline_cmd)
  if git_err or not baseline_content or baseline_content:match '^fatal:' or baseline_content:match '^error:' then
    baseline_content = ''
  elseif baseline_content ~= '' and not baseline_content:match '\n$' then
    baseline_content = baseline_content .. '\n'
  end

  -- Apply hunk to baseline content
  local updated_baseline_content = M.apply_patch_to_content(baseline_content, hunk_patch, false, relative_path)
  if not updated_baseline_content then
    return { status = 'error', actions = {}, info = { reason = 'patch_failed', bufnr = bufnr, file = file_path } }
  end

  -- Determine if this clears all hunks by comparing new baseline vs current buffer
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')
  local new_diff = diffmod.compute_diff(updated_baseline_content, current_content)
  local actions
  if updated_baseline_content == '' then
    actions = {
      action('baseline_remove_file', { git_root = git_root, relative_path = relative_path, reason = 'accept_delete' }),
      action('buffer_close', { bufnr = bufnr }),
    }
  else
    actions = {
      action('baseline_update_file', {
        git_root = git_root,
        relative_path = relative_path,
        new_content = updated_baseline_content,
        reason = 'accept_hunk',
      })
    }
  end
  if not new_diff or not new_diff.hunks or #new_diff.hunks == 0 then
    table.insert(actions, action('project_untrack_file', { git_root = git_root, relative_path = relative_path }))
  end

  return {
    status = 'ok',
    actions = actions,
    info = { bufnr = bufnr, file = file_path },
  }
end

-- Rejection for existing file: build actions to apply reverse patch to worktree and reload
local function reject_hunk_in_worktree_actions(bufnr, hunk)
  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  -- Build reverse patch
  local patch = M.generate_hunk_patch(hunk, relative_path)
  return {
    action('worktree_apply_reverse_patch', { git_root = git_root, relative_path = relative_path, patch = patch }),
    action('buffer_reload', { bufnr = bufnr }),
  }
end

-- For new files: compute buffer content after removing added lines from the hunk
local function compute_manual_reject_content(bufnr, hunk)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local new_lines = {}

  local hunk_start = hunk.new_start
  local additions_count = 0
  for _, line in ipairs(hunk.lines or {}) do
    if line:match '^%+' then
      additions_count = additions_count + 1
    end
  end

  -- Copy lines before the hunk
  for i = 1, hunk_start - 1 do
    if lines[i] then
      table.insert(new_lines, lines[i])
    end
  end
  -- Skip added lines, then copy remaining
  for i = hunk_start + additions_count, #lines do
    if lines[i] then
      table.insert(new_lines, lines[i])
    end
  end

  return table.concat(new_lines, '\n')
end

-- Public: accept the current hunk for a buffer
function M.accept_current_hunk(bufnr, active_diffs)
  local data = active_diffs[bufnr]
  if not data then
    return { status = 'error', actions = {}, info = { reason = 'no_diff_data', bufnr = bufnr } }
  end
  local hunk_idx = data.current_hunk
  local hunk = data.hunks[hunk_idx]
  if not hunk then
    return { status = 'error', actions = {}, info = { reason = 'no_hunk', bufnr = bufnr } }
  end
  return M.accept_hunk_for_file(bufnr, hunk)
end

-- Public: reject the current hunk for a buffer
function M.reject_current_hunk(bufnr, active_diffs)
  local data = active_diffs[bufnr]
  if not data then
    return { status = 'error', actions = {}, info = { reason = 'no_diff_data', bufnr = bufnr } }
  end
  local hunk_idx = data.current_hunk
  local hunk = data.hunks[hunk_idx]
  if not hunk then
    return { status = 'error', actions = {}, info = { reason = 'no_hunk', bufnr = bufnr } }
  end

  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  -- Determine if file exists in baseline
  local ref = baseline.get_baseline_ref(git_root)
  local baseline_check = ref and utils.exec(string.format("cd '%s' && git show %s:'%s' 2>&1", git_root, ref, relative_path)) or nil
  if baseline_check and (baseline_check:match '^fatal:' or baseline_check:match 'does not exist') then
    -- New file: plan to remove lines; if empty, plan to delete & untrack
    local new_content = compute_manual_reject_content(bufnr, hunk)
    local actions = { action('buffer_set_content', { bufnr = bufnr, content = new_content }), action('buffer_write', { bufnr = bufnr }) }
    local is_empty = (new_content == '' or new_content == nil)
    if is_empty then
      table.insert(actions, action('file_delete', { path = file_path }))
      table.insert(actions, action('buffer_close', { bufnr = bufnr }))
      table.insert(actions, action('project_untrack_file', { git_root = git_root, relative_path = relative_path }))
    end
    return { status = 'ok', actions = actions, info = { bufnr = bufnr, file = file_path } }
  else
    -- Existing file: compute new buffer content by reverse applying hunk patch
    local patch = M.generate_hunk_patch(hunk, relative_path)
    local current_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    local new_content = M.apply_patch_to_content(current_content, patch, true, relative_path)
    if not new_content then
      return { status = 'error', actions = {}, info = { reason = 'reverse_patch_failed', file = file_path } }
    end
    local actions = {
      action('buffer_set_content', { bufnr = bufnr, content = new_content }),
      action('buffer_write', { bufnr = bufnr }),
    }
    -- If no hunks remain after rejection, untrack
    local base_content = utils.exec(string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, ref, relative_path)) or ''
    local new_diff = diffmod.compute_diff(base_content, new_content)
    if not new_diff or not new_diff.hunks or #new_diff.hunks == 0 then
      table.insert(actions, action('project_untrack_file', { git_root = git_root, relative_path = relative_path }))
    end
    return { status = 'ok', actions = actions, info = { bufnr = bufnr, file = file_path } }
  end
end

-- Accept all hunks in current file by updating baseline to match buffer
function M.accept_all_hunks_in_file(bufnr)
  local git_root = utils.get_project_root()
  if not git_root then
    return { status = 'error', actions = {}, info = { reason = 'no_root' } }
  end
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  local ref = baseline.get_baseline_ref(git_root)
  if not ref then
    return { status = 'error', actions = {}, info = { reason = 'no_baseline', file = file_path } }
  end

  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')
  if current_content == '' then
    return {
      status = 'ok',
      actions = {
        action('baseline_remove_file', { git_root = git_root, relative_path = relative_path, reason = 'accept_delete_all' }),
        action('buffer_close', { bufnr = bufnr }),
        action('project_untrack_file', { git_root = git_root, relative_path = relative_path }),
      },
      info = { bufnr = bufnr, file = file_path },
    }
  else
    if current_content ~= '' and not current_content:match '\n$' then
      current_content = current_content .. '\n'
    end
    return {
      status = 'ok',
      actions = {
        action('baseline_update_file', { git_root = git_root, relative_path = relative_path, new_content = current_content, reason = 'accept_all' }),
        action('project_untrack_file', { git_root = git_root, relative_path = relative_path }),
      },
      info = { bufnr = bufnr, file = file_path },
    }
  end
end

-- Reject all hunks in current file by restoring buffer to baseline content (or deleting new file)
function M.reject_all_hunks_in_file(bufnr)
  local git_root = utils.get_project_root()
  if not git_root then
    return { status = 'error', actions = {}, info = { reason = 'no_root' } }
  end
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  local ref = baseline.get_baseline_ref(git_root)
  if not ref then
    return { status = 'error', actions = {}, info = { reason = 'no_baseline', file = file_path } }
  end

  local baseline_cmd = string.format("cd '%s' && git show %s:'%s' 2>&1", git_root, ref, relative_path)
  local baseline_content, err = utils.exec(baseline_cmd)

  if baseline_content and (baseline_content:match '^fatal:' or baseline_content:match 'does not exist') then
    return {
      status = 'ok',
      actions = {
        action('file_delete', { path = file_path }),
        action('buffer_close', { bufnr = bufnr }),
        action('project_untrack_file', { git_root = git_root, relative_path = relative_path }),
      },
      info = { bufnr = bufnr, file = file_path },
    }
  else
    if err or not baseline_content or baseline_content == '' then
      return { status = 'error', actions = {}, info = { reason = 'baseline_read_failed', file = file_path } }
    end
    return {
      status = 'ok',
      actions = {
        action('buffer_set_content', { bufnr = bufnr, content = baseline_content }),
        action('buffer_write', { bufnr = bufnr }),
        action('project_untrack_file', { git_root = git_root, relative_path = relative_path }),
      },
      info = { bufnr = bufnr, file = file_path },
    }
  end
end

-- Batch helpers operating on active_diffs map (open buffers)
function M.accept_all_hunks_in_all_files(active_diffs)
  local actions = {}
  for bufnr, data in pairs(active_diffs or {}) do
    if data and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local plan = M.accept_all_hunks_in_file(bufnr)
      if plan and plan.actions then
        for _, a in ipairs(plan.actions) do
          table.insert(actions, a)
        end
      end
    end
  end
  return { status = 'ok', actions = actions }
end

function M.reject_all_hunks_in_all_files(active_diffs)
  local actions = {}
  for bufnr, data in pairs(active_diffs or {}) do
    if data and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local plan = M.reject_all_hunks_in_file(bufnr)
      if plan and plan.actions then
        for _, a in ipairs(plan.actions) do
          table.insert(actions, a)
        end
      end
    end
  end
  return { status = 'ok', actions = actions }
end

-- Global accept/reject operations across all edited files
-- Note: these operate at the data layer (baseline + filesystem + project_state).
-- UI behaviors (like closing or switching buffers) should be handled by the facade.
local navigation = require 'nvim-claude.inline_diff.navigation'
local project_state = require 'nvim-claude.project-state'

function M.accept_all_files()
  local root, items = navigation.get_edited_items()
  if not root or #items == 0 then return { ok = false, reason = 'no_items' } end
  for _, it in ipairs(items) do
    local ref = baseline.get_baseline_ref(root)
    if it.deleted then
      baseline.remove_from_baseline(root, it.rel, ref)
    else
      local full = root .. '/' .. it.rel
      local content = utils.read_file(full) or ''
      baseline.update_baseline_with_content(root, it.rel, content, ref)
    end
    local map = project_state.get(root, 'claude_edited_files') or {}
    map[it.rel] = nil
    project_state.set(root, 'claude_edited_files', map)
  end
  return { ok = true, root = root, items = items }
end

function M.reject_all_files()
  local root, items = navigation.get_edited_items()
  if not root or #items == 0 then return { ok = false, reason = 'no_items' } end
  local ref = baseline.get_baseline_ref(root)
  for _, it in ipairs(items) do
    local full = root .. '/' .. it.rel
    local base = ''
    if ref and ref ~= '' then
      local cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", root, ref, it.rel)
      base = utils.exec(cmd) or ''
      if base:match('^fatal:') or base:match('^error:') then base = '' end
    end
    if it.deleted then
      utils.ensure_dir(vim.fn.fnamemodify(full, ':h'))
      utils.write_file(full, base)
    else
      if base == '' then pcall(os.remove, full) else utils.write_file(full, base) end
    end
    local map = project_state.get(root, 'claude_edited_files') or {}
    map[it.rel] = nil
    project_state.set(root, 'claude_edited_files', map)
  end
  return { ok = true, root = root, items = items }
end

return M
