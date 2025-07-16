-- Inline diff viewer for nvim-claude
-- Shows Claude's changes directly in the current buffer with accept/reject functionality

local M = {}

-- Namespace for virtual text and highlights
local ns_id = vim.api.nvim_create_namespace 'nvim_claude_inline_diff'

-- State tracking
M.active_diffs = {} -- Track active inline diffs by buffer number

-- Initialize inline diff for a buffer
function M.show_inline_diff(bufnr, old_content, new_content)
  bufnr = bufnr or vim.api.nvim_get_current_buf()


  -- Get the diff between old and new content
  local diff_data = M.compute_diff(old_content, new_content)

  if not diff_data or #diff_data.hunks == 0 then
    vim.notify('No changes to display', vim.log.levels.INFO)
    return
  end

  -- Store diff data for this buffer
  M.active_diffs[bufnr] = {
    hunks = diff_data.hunks,
    current_hunk = 1,
  }

  -- Store target content for diff

  -- Apply visual indicators
  M.apply_diff_visualization(bufnr)

  -- Set up buffer-local keymaps
  M.setup_inline_keymaps(bufnr)

  -- Jump to first hunk
  M.jump_to_hunk(bufnr, 1)

  -- Silent activation - no notification
end

-- Compute diff between two texts
function M.compute_diff(old_text, new_text)
  local utils = require 'nvim-claude.utils'

  -- Ensure consistent newline endings to avoid phantom diffs
  -- Both texts should end with newline for consistent git diff behavior
  if old_text ~= '' and not old_text:match '\n$' then
    old_text = old_text .. '\n'
  end
  if new_text ~= '' and not new_text:match '\n$' then
    new_text = new_text .. '\n'
  end

  -- Write texts to temp files
  local old_file = '/tmp/nvim-claude-old.txt'
  local new_file = '/tmp/nvim-claude-new.txt'

  utils.write_file(old_file, old_text)
  utils.write_file(new_file, new_text)

  -- Use git diff with histogram algorithm for better code diffs
  local cmd = string.format('git diff --no-index --no-prefix --unified=1 --diff-algorithm=histogram "%s" "%s" 2>/dev/null || true', old_file, new_file)
  local diff_output = utils.exec(cmd)

  -- Parse diff into hunks

  -- Parse diff into hunks
  local hunks = M.parse_diff(diff_output)

  return {
    hunks = hunks,
  }
end

-- Parse unified diff output into hunk structures
function M.parse_diff(diff_text)
  local hunks = {}
  local current_hunk = nil
  local in_hunk = false

  for line in diff_text:gmatch '[^\r\n]+' do
    if line:match '^@@' then
      -- New hunk header
      if current_hunk then
        table.insert(hunks, current_hunk)
      end

      local old_start, old_count, new_start, new_count = line:match '^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@'
      current_hunk = {
        old_start = tonumber(old_start),
        old_count = tonumber(old_count) or 1,
        new_start = tonumber(new_start),
        new_count = tonumber(new_count) or 1,
        lines = {},
        header = line,
      }
      in_hunk = true
    elseif in_hunk and (line:match '^[%+%-]' or line:match '^%s') then
      -- Diff line
      table.insert(current_hunk.lines, line)
    elseif line:match '^diff %-%-git' or line:match '^index ' or line:match '^%+%+%+ ' or line:match '^%-%-%-' then
      -- Skip git diff headers
      in_hunk = false
    end
  end

  -- Add last hunk
  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

-- Apply visual indicators for diff with line highlights
function M.apply_diff_visualization(bufnr)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data then
    return
  end

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Get current buffer lines for reference
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Apply highlights for each hunk
  for i, hunk in ipairs(diff_data.hunks) do
    -- Track which lines in the current buffer correspond to additions/deletions
    local additions = {}
    local deletions = {}

    -- Start from the beginning of the hunk and track line numbers
    local new_line_num = hunk.new_start -- 1-indexed line number in new file
    local old_line_num = hunk.old_start -- 1-indexed line number in old file

    -- First, detect if this hunk is a replacement (has both - and + lines)
    local has_deletions = false
    local has_additions = false
    for _, diff_line in ipairs(hunk.lines) do
      if diff_line:match '^%-' then
        has_deletions = true
      end
      if diff_line:match '^%+' then
        has_additions = true
      end
    end
    local is_replacement = has_deletions and has_additions

    for _, diff_line in ipairs(hunk.lines) do
      if diff_line:match '^%+' then
        -- This is an added line - it exists in the current buffer at new_line_num
        table.insert(additions, new_line_num - 1) -- Convert to 0-indexed for extmarks
        new_line_num = new_line_num + 1
        -- Don't advance old_line_num for additions
      elseif diff_line:match '^%-' then
        -- This is a deleted line - show as virtual text above current position
        -- For replacements, the deletion should appear above the addition
        local del_line = new_line_num - 1
        if is_replacement and #additions > 0 then
          -- Place deletion above the first addition
          del_line = additions[1]
        end
        table.insert(deletions, {
          line = del_line, -- 0-indexed
          text = diff_line:sub(2),
        })
        old_line_num = old_line_num + 1
        -- Don't advance new_line_num for deletions
      elseif diff_line:match '^%s' then
        -- Context line - advance both
        new_line_num = new_line_num + 1
        old_line_num = old_line_num + 1
      end
    end

    -- Apply highlighting for additions
    for _, line_idx in ipairs(additions) do
      if line_idx >= 0 and line_idx < #buf_lines then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
          line_hl_group = 'DiffAdd',
          id = 4000 + i * 1000 + line_idx,
        })
      end
    end

    -- Show deletions as virtual text above their position with full-width background
    for j, del in ipairs(deletions) do
      -- Determine if this is an EOF deletion
      local is_eof_deletion = del.line >= #buf_lines
      local placement_line = is_eof_deletion and (#buf_lines - 1) or del.line

      if placement_line >= 0 and placement_line < #buf_lines then
        -- Calculate full width for the deletion line
        local text = '- ' .. del.text
        local win_width = vim.api.nvim_win_get_width(0)

        -- For deletion-only hunks, add hunk info to the first deletion
        local hunk_indicator = ''
        if j == 1 and #additions == 0 then
          -- This is a deletion-only hunk, add the hunk indicator
          hunk_indicator = ' [Hunk ' .. i .. '/' .. #diff_data.hunks .. ']'
        end

        -- Build virtual line parts
        local virt_line_parts = {}
        if hunk_indicator ~= '' then
          -- Structure: deletion text + hunk indicator + padding to fill the rest
          table.insert(virt_line_parts, { text, 'DiffDelete' })
          table.insert(virt_line_parts, { hunk_indicator, 'Comment' })

          -- Calculate remaining width and fill with red background
          local used_width = vim.fn.strdisplaywidth(text) + vim.fn.strdisplaywidth(hunk_indicator)
          local remaining_width = win_width - used_width
          if remaining_width > 0 then
            local padding = string.rep(' ', remaining_width)
            table.insert(virt_line_parts, { padding, 'DiffDelete' })
          end
        else
          -- Normal deletion line - keep full width for visibility
          local padding = string.rep(' ', math.max(0, win_width - vim.fn.strdisplaywidth(text)))
          table.insert(virt_line_parts, { text .. padding, 'DiffDelete' })
        end

        vim.api.nvim_buf_set_extmark(bufnr, ns_id, placement_line, 0, {
          virt_lines = { virt_line_parts },
          virt_lines_above = not is_eof_deletion, -- EOF deletions appear below the last line
          id = 3000 + i * 100 + j,
        })
      end
    end

    -- Add sign in gutter for hunk (use first addition or deletion line)
    local sign_line = nil
    if #additions > 0 then
      sign_line = additions[1]
    elseif #deletions > 0 then
      sign_line = deletions[1].line
    else
      sign_line = hunk.new_start - 1
    end

    local sign_text = '>'
    local sign_hl = 'DiffAdd'

    -- If hunk has deletions, use different sign
    if #deletions > 0 then
      sign_text = '~'
      sign_hl = 'DiffChange'
    end

    if sign_line and sign_line >= 0 and sign_line < #buf_lines then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, sign_line, 0, {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
        id = 2000 + i,
      })
    end

    -- Add subtle hunk info at end of first changed line (only for hunks with additions)
    if #additions > 0 then
      local info_line = sign_line
      if info_line and info_line >= 0 and info_line < #buf_lines then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, info_line, 0, {
          virt_text = { { ' [Hunk ' .. i .. '/' .. #diff_data.hunks .. ']', 'Comment' } },
          virt_text_pos = 'eol',
          id = 1000 + i,
        })
      end
    end
  end
end

-- Set up buffer-local keymaps for inline diff
function M.setup_inline_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true }

  -- Set up auto-refresh on text changes (debounced)
  M.setup_auto_refresh(bufnr)

  -- Navigation between hunks
  vim.keymap.set('n', ']h', function()
    M.next_hunk(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Next Claude hunk' }))
  vim.keymap.set('n', '[h', function()
    M.prev_hunk(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Previous Claude hunk' }))

  -- Accept/Reject
  vim.keymap.set('n', '<leader>ia', function()
    M.accept_current_hunk(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Accept Claude hunk' }))
  vim.keymap.set('n', '<leader>ir', function()
    M.reject_current_hunk(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Reject Claude hunk' }))

  -- Accept/Reject all in current file
  vim.keymap.set('n', '<leader>iA', function()
    M.accept_all_hunks(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Accept all Claude hunks in current file' }))
  vim.keymap.set('n', '<leader>iR', function()
    M.reject_all_hunks(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Reject all Claude hunks in current file' }))

  -- List files with diffs
  vim.keymap.set('n', '<leader>il', function()
    M.list_diff_files()
  end, vim.tbl_extend('force', opts, { desc = 'List files with Claude diffs' }))

  -- Exit inline diff
  vim.keymap.set('n', '<leader>iq', function()
    M.close_inline_diff(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Close inline diff' }))

  -- Manual refresh
  vim.keymap.set('n', '<leader>if', function()
    M.refresh_inline_diff(bufnr)
  end, vim.tbl_extend('force', opts, { desc = 'Refresh inline diff' }))
end

-- Jump to specific hunk
function M.jump_to_hunk(bufnr, hunk_idx)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data or not diff_data.hunks[hunk_idx] then
    return
  end

  local hunk = diff_data.hunks[hunk_idx]
  diff_data.current_hunk = hunk_idx

  -- Find the first actual changed line (addition or deletion) in this hunk
  local jump_line = nil
  local new_line_num = hunk.new_start -- 1-indexed line number in new file

  for _, diff_line in ipairs(hunk.lines) do
    if diff_line:match '^%+' then
      -- Found an addition - jump here
      jump_line = new_line_num
      break
    elseif diff_line:match '^%-' then
      -- Found a deletion - jump here
      jump_line = new_line_num
      break
    elseif diff_line:match '^%s' then
      -- Context line - advance
      new_line_num = new_line_num + 1
    end
  end

  -- Fallback to hunk start if no changes found
  if not jump_line then
    jump_line = hunk.new_start
  end

  -- Get buffer line count to ensure we don't jump past the end
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- For deletions at the end of file, jump to the last line
  if jump_line > line_count then
    jump_line = math.max(1, line_count)
  end

  -- Move cursor to the actual changed line (only if we have a valid window)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    vim.api.nvim_win_set_cursor(win, { jump_line, 0 })
  end

  -- Update status
  vim.notify(string.format('Hunk %d/%d', hunk_idx, #diff_data.hunks), vim.log.levels.INFO)
end

-- Navigate to next hunk
function M.next_hunk(bufnr)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data then
    return
  end

  local next_idx = diff_data.current_hunk + 1
  if next_idx > #diff_data.hunks then
    next_idx = 1
  end

  M.jump_to_hunk(bufnr, next_idx)
end

-- Navigate to previous hunk
function M.prev_hunk(bufnr)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data then
    return
  end

  local prev_idx = diff_data.current_hunk - 1
  if prev_idx < 1 then
    prev_idx = #diff_data.hunks
  end

  M.jump_to_hunk(bufnr, prev_idx)
end

-- Generate a patch for a single hunk
function M.generate_hunk_patch(hunk, file_path)
  local patch_lines = {
    string.format('--- a/%s', file_path),
    string.format('+++ b/%s', file_path),
    hunk.header,
  }

  -- Add the hunk lines
  for _, line in ipairs(hunk.lines) do
    table.insert(patch_lines, line)
  end

  -- Ensure patch ends with newline
  table.insert(patch_lines, '')

  return table.concat(patch_lines, '\n')
end

-- Apply patch to content string using git operations
function M.apply_patch_to_content(content, patch)
  local utils = require 'nvim-claude.utils'

  -- Create a temporary directory for patch application
  local temp_dir = '/tmp/nvim-claude-patch-' .. os.time()
  -- Create temp directory
  vim.fn.mkdir(temp_dir, 'p')

  -- Simple approach: always use 'file' as the filename to avoid path issues
  local temp_file = temp_dir .. '/file'
  local patch_file = temp_dir .. '/patch.patch'

  -- Write the baseline content
  local success = utils.write_file(temp_file, content)
  if not success then
    return nil
  end

  -- Modify patch to use generic filename 'file' instead of actual filename
  local modified_patch = patch:gsub('--- a/[^\n]+', '--- a/file'):gsub('%+%+%+ b/[^\n]+', '+++ b/file')

  -- Write the modified patch file
  success = utils.write_file(patch_file, modified_patch)
  if not success then
    return nil
  end

  -- Apply patch using patch command
  local cmd = string.format('cd "%s" && patch -p1 < "%s" 2>&1', temp_dir, patch_file)
  local result, err = utils.exec(cmd)

  local patched_content = nil

  if not err then
    -- Patch applied successfully, read the result
    patched_content = utils.read_file(temp_file)
  else
    -- Patch failed, return nil
  end

  -- Cleanup
  os.execute('rm -rf "' .. temp_dir .. '"')

  return patched_content
end

-- Update baseline stash with new content for a specific file
function M.update_baseline_with_content(git_root, relative_path, content, current_stash_ref)
  local utils = require 'nvim-claude.utils'
  local hooks = require 'nvim-claude.hooks'

  -- Simpler approach: use a temporary index to create a new commit
  local success = pcall(function()
    -- Create a unique temporary directory
    local temp_dir = '/tmp/nvim-claude-baseline-' .. os.time() .. '-' .. math.random(10000)
    vim.fn.mkdir(temp_dir, 'p')

    -- Set up temporary index file
    local temp_index = temp_dir .. '/index'

    -- Read the tree from current baseline into temporary index
    local read_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git read-tree %s', git_root, temp_index, current_stash_ref)
    local read_result, read_err = utils.exec(read_tree_cmd)
    if read_err then
      error('Failed to read baseline tree: ' .. read_err)
    end

    -- Write content to temporary file
    local temp_file = temp_dir .. '/content'
    utils.write_file(temp_file, content)

    -- Create blob first and validate the hash
    local hash_cmd = string.format('cd "%s" && git hash-object -w "%s"', git_root, temp_file)
    local blob_hash, hash_err = utils.exec(hash_cmd)
    if hash_err or not blob_hash or blob_hash:match '^fatal:' or blob_hash:match '^error:' then
      error('Failed to create blob: ' .. (hash_err or blob_hash or 'unknown error'))
    end
    blob_hash = blob_hash:gsub('%s+$', '') -- trim whitespace

    -- Update the specific file in the temporary index
    local update_cmd =
      string.format('cd "%s" && GIT_INDEX_FILE="%s" git update-index --add --cacheinfo 100644,%s,"%s"', git_root, temp_index, blob_hash, relative_path)
    local update_result, update_err = utils.exec(update_cmd)
    if update_err or (update_result and (update_result:match '^fatal:' or update_result:match '^error:')) then
      error('Failed to update file in index: ' .. (update_err or update_result or 'unknown error'))
    end

    -- Create tree from temporary index
    local write_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
    local new_tree_hash, tree_err = utils.exec(write_tree_cmd)
    if tree_err or not new_tree_hash or new_tree_hash:match '^fatal:' or new_tree_hash:match '^error:' then
      error('Failed to write tree: ' .. (tree_err or new_tree_hash or 'unknown error'))
    end
    new_tree_hash = new_tree_hash:gsub('%s+$', '')

    -- Create new commit
    local commit_message = string.format('nvim-claude: accept hunk in %s %s', relative_path, os.date '%Y-%m-%d %H:%M:%S')
    local commit_cmd = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', git_root, new_tree_hash, current_stash_ref, commit_message)
    local new_commit_hash, commit_err = utils.exec(commit_cmd)
    if commit_err or not new_commit_hash or new_commit_hash:match '^fatal:' or new_commit_hash:match '^error:' then
      error('Failed to create commit: ' .. (commit_err or new_commit_hash or 'unknown error'))
    end
    new_commit_hash = new_commit_hash:gsub('%s+$', '')

    -- Validate the final commit hash before using it
    if new_commit_hash:match 'fatal:' or new_commit_hash:match 'error:' then
      error('Got error message instead of commit hash: ' .. new_commit_hash)
    end

    -- Cleanup temporary directory
    vim.fn.delete(temp_dir, 'rf')

    -- Update baseline reference
    hooks.stable_baseline_ref = new_commit_hash

    return true
  end)

  return success
end

-- Simplified approach: update baseline in memory only
-- The complex git stash approach was causing issues
function M.update_file_baseline(bufnr)
  -- No longer storing in memory - we always read from git stash
  -- Just save state for persistence
  local persistence = require 'nvim-claude.inline-diff-persistence'
  if persistence.current_stash_ref then
    persistence.save_state { stash_ref = persistence.current_stash_ref }
  end
end

-- Accept current hunk
function M.accept_current_hunk(bufnr)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data then
    vim.notify('No diff data found for buffer', vim.log.levels.ERROR)
    return
  end

  local hunk_idx = diff_data.current_hunk
  local hunk = diff_data.hunks[hunk_idx]
  if not hunk then
    vim.notify('No hunk found at index ' .. hunk_idx, vim.log.levels.ERROR)
    return
  end

  local utils = require 'nvim-claude.utils'
  local hooks = require 'nvim-claude.hooks'
  local persistence = require 'nvim-claude.inline-diff-persistence'
  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  -- Step 1: Generate patch for current hunk only
  local hunk_patch = M.generate_hunk_patch(hunk, relative_path)

  -- Step 2: Get current baseline from stash
  local stash_ref = hooks.stable_baseline_ref or persistence.current_stash_ref
  if not stash_ref then
    vim.notify('No baseline stash found', vim.log.levels.ERROR)
    return
  end

  local baseline_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, stash_ref, relative_path)
  local baseline_content, git_err = utils.exec(baseline_cmd)
  if git_err or not baseline_content then
    baseline_content = '' -- Treat as new file
  end

  -- Step 3: Apply patch to baseline
  local updated_baseline_content = M.apply_patch_to_content(baseline_content, hunk_patch)
  if not updated_baseline_content then
    vim.notify('Failed to apply patch to baseline', vim.log.levels.ERROR)
    return
  end

  -- Step 4: Update baseline stash with patched content
  local success = M.update_baseline_with_content(git_root, relative_path, updated_baseline_content, stash_ref)
  if not success then
    vim.notify('Failed to update baseline stash', vim.log.levels.ERROR)
    return
  end

  -- Step 5: Recompute diff against updated baseline
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')
  local new_diff_data = M.compute_diff(updated_baseline_content, current_content)

  -- Step 6: Update state based on remaining hunks
  if not new_diff_data or #new_diff_data.hunks == 0 then
    -- No more hunks, remove from tracking
    vim.notify('All changes accepted for this file.', vim.log.levels.INFO)

    hooks.claude_edited_files[relative_path] = nil
    persistence.save_state {
      stash_ref = hooks.stable_baseline_ref,
      claude_edited_files = hooks.claude_edited_files,
    }

    M.close_inline_diff(bufnr, true)
  else
    -- Update active_diffs with new hunk data
    local next_hunk_idx = math.min(hunk_idx, #new_diff_data.hunks)
    M.active_diffs[bufnr] = {
      hunks = new_diff_data.hunks,
      current_hunk = next_hunk_idx,
    }

    -- Re-render visualization for remaining hunks
    M.apply_diff_visualization(bufnr)

    -- Navigate to next hunk
    M.jump_to_hunk(bufnr, next_hunk_idx)

    vim.notify(string.format('Hunk accepted. %d hunks remaining.', #new_diff_data.hunks), vim.log.levels.INFO)
  end
end

-- Reject current hunk
function M.reject_current_hunk(bufnr)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data then
    vim.notify('No diff data for buffer', vim.log.levels.ERROR)
    return
  end

  local hunk_idx = diff_data.current_hunk
  local hunk = diff_data.hunks[hunk_idx]
  if not hunk then
    vim.notify('No hunk at index ' .. tostring(hunk_idx), vim.log.levels.ERROR)
    return
  end

  -- For reject, apply the patch in reverse to the current file
  -- The baseline stays unchanged
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  -- Generate patch for this hunk
  local patch = M.generate_hunk_patch(hunk, relative_path)
  local patch_file = vim.fn.tempname() .. '.patch'
  utils.write_file(patch_file, patch)

  -- Apply reverse patch to the working directory
  local apply_cmd = string.format('cd "%s" && git apply --reverse --verbose "%s" 2>&1', git_root, patch_file)
  local result, err = utils.exec(apply_cmd)

  if err or (result and result:match 'error:') then
    vim.notify('Failed to reject hunk: ' .. (err or result), vim.log.levels.ERROR)
    vim.fn.delete(patch_file)
    return
  end

  vim.fn.delete(patch_file)

  -- Reload the buffer
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd 'checktime'
  end)

  -- Recalculate diff against unchanged baseline
  local hooks = require 'nvim-claude.hooks'

  -- Get the new baseline content
  local stash_ref = hooks.stable_baseline_ref
  if not stash_ref then
    vim.notify('No baseline stash reference found', vim.log.levels.ERROR)
    return
  end
  local baseline_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, stash_ref, relative_path)
  local new_baseline = utils.exec(baseline_cmd)

  if new_baseline then
    -- Get current content
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local current_content = table.concat(current_lines, '\n')

    -- Recalculate diff
    local new_diff_data = M.compute_diff(new_baseline, current_content)

    if not new_diff_data or #new_diff_data.hunks == 0 then
      vim.notify('All changes rejected for this file.', vim.log.levels.INFO)

      -- Remove this file from Claude edited files tracking
      if hooks.claude_edited_files[relative_path] then
        hooks.claude_edited_files[relative_path] = nil
        local persistence = require 'nvim-claude.inline-diff-persistence'
        persistence.save_state {
          stash_ref = persistence.current_stash_ref,
          claude_edited_files = hooks.claude_edited_files,
        }
      end

      M.close_inline_diff(bufnr, false)
    else
      -- Update diff data
      diff_data.hunks = new_diff_data.hunks
      diff_data.current_hunk = 1

      -- Refresh visualization
      M.apply_diff_visualization(bufnr)
      M.jump_to_hunk(bufnr, 1)
      vim.notify(string.format('%d hunks remaining', #new_diff_data.hunks), vim.log.levels.INFO)
    end
  end
end

-- Revert hunk changes (restore original content)
function M.revert_hunk_changes(bufnr, hunk)
  -- Get current buffer lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Extract the expected content from the hunk
  local expected_lines = {}
  local original_lines = {}

  for _, diff_line in ipairs(hunk.lines) do
    if diff_line:match '^%+' then
      -- Lines that were added (these should be in current buffer)
      table.insert(expected_lines, diff_line:sub(2))
    elseif diff_line:match '^%-' then
      -- Lines that were removed (these should be restored)
      table.insert(original_lines, diff_line:sub(2))
    elseif diff_line:match '^%s' then
      -- Context lines (should be in both)
      table.insert(expected_lines, diff_line:sub(2))
      table.insert(original_lines, diff_line:sub(2))
    end
  end

  -- Find where this hunk actually is in the current buffer
  -- We'll look for the best match by checking context lines too
  local hunk_start = nil
  local hunk_end = nil
  local best_score = -1
  local best_start = nil

  -- Include some context before and after for better matching
  local context_before = {}
  local context_after = {}

  -- Extract context from the diff
  local in_changes = false
  for i, diff_line in ipairs(hunk.lines) do
    if diff_line:match '^[%+%-]' then
      in_changes = true
    elseif diff_line:match '^%s' and not in_changes then
      -- Context before changes
      table.insert(context_before, diff_line:sub(2))
    elseif diff_line:match '^%s' and in_changes then
      -- Context after changes
      table.insert(context_after, diff_line:sub(2))
    end
  end

  -- Search for the hunk by matching content with context
  for i = 1, #lines - #expected_lines + 1 do
    local score = 0
    local matches = true

    -- Check the main content
    for j = 1, #expected_lines do
      if lines[i + j - 1] == expected_lines[j] then
        score = score + 1
      else
        matches = false
      end
    end

    if matches then
      -- Bonus points for matching context before
      local before_start = i - #context_before
      if before_start > 0 then
        for j = 1, #context_before do
          if lines[before_start + j - 1] == context_before[j] then
            score = score + 2 -- Context is worth more
          end
        end
      end

      -- Bonus points for matching context after
      local after_start = i + #expected_lines
      if after_start + #context_after - 1 <= #lines then
        for j = 1, #context_after do
          if lines[after_start + j - 1] == context_after[j] then
            score = score + 2 -- Context is worth more
          end
        end
      end

      -- Keep the best match
      if score > best_score then
        best_score = score
        best_start = i
      end
    end
  end

  if best_start then
    hunk_start = best_start
    hunk_end = best_start + #expected_lines - 1
  else
    vim.notify('Could not find hunk in current buffer - content may have changed', vim.log.levels.ERROR)
    return
  end

  -- Build new buffer content
  local new_lines = {}

  -- Copy lines before the hunk
  for i = 1, hunk_start - 1 do
    table.insert(new_lines, lines[i])
  end

  -- Insert the original lines
  for _, line in ipairs(original_lines) do
    table.insert(new_lines, line)
  end

  -- Copy lines after the hunk
  for i = hunk_end + 1, #lines do
    table.insert(new_lines, lines[i])
  end

  -- Update buffer
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

-- Apply hunk changes to buffer
function M.apply_hunk_changes(bufnr, hunk)
  -- Get current buffer lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Build new lines with hunk applied
  local new_lines = {}
  local buffer_line = 1
  local hunk_line = 1
  local applied = false

  while buffer_line <= #lines do
    if buffer_line == hunk.old_start and not applied then
      -- Apply hunk here
      for _, diff_line in ipairs(hunk.lines) do
        if diff_line:match '^%+' then
          -- Add new line
          table.insert(new_lines, diff_line:sub(2))
        elseif diff_line:match '^%-' then
          -- Skip deleted line
          buffer_line = buffer_line + 1
        else
          -- Keep context line
          table.insert(new_lines, lines[buffer_line])
          buffer_line = buffer_line + 1
        end
      end
      applied = true
    else
      -- Copy unchanged line
      if buffer_line <= #lines then
        table.insert(new_lines, lines[buffer_line])
      end
      buffer_line = buffer_line + 1
    end
  end

  -- Update buffer
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

-- Accept all hunks
function M.accept_all_hunks(bufnr)
  local diff_data = M.active_diffs[bufnr]
  if not diff_data then
    return
  end

  -- Get current buffer content as the new baseline
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')

  -- Remove this file from Claude edited files tracking
  local utils = require 'nvim-claude.utils'
  local hooks = require 'nvim-claude.hooks'
  local git_root = utils.get_project_root()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  if hooks.claude_edited_files[relative_path] then
    hooks.claude_edited_files[relative_path] = nil
  end

  vim.notify('Accepted all Claude changes', vim.log.levels.INFO)

  -- Close inline diff
  M.close_inline_diff(bufnr)
end

-- Reject all hunks
function M.reject_all_hunks(bufnr)
  vim.notify('Rejected all Claude changes', vim.log.levels.INFO)

  -- Close inline diff
  M.close_inline_diff(bufnr)

  -- Clear baseline tracking for consistency with accept all
  local hooks = require 'nvim-claude.hooks'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Check if there are any other tracked files
  local has_other_files = false
  local current_file = vim.api.nvim_buf_get_name(bufnr)
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()
  local relative_path = current_file:gsub('^' .. vim.pesc(git_root) .. '/', '')

  for file_path, _ in pairs(hooks.claude_edited_files) do
    if file_path ~= relative_path then
      has_other_files = true
      break
    end
  end

  -- If no other files are tracked, clear the baseline
  if not has_other_files then
    hooks.stable_baseline_ref = nil
    persistence.clear_state()
  end
end

-- Close inline diff mode
function M.close_inline_diff(bufnr, keep_baseline)
  -- Clear highlights and virtual text
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Remove buffer-local keymaps
  pcall(vim.keymap.del, 'n', ']h', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '[h', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '<leader>ia', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '<leader>ir', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '<leader>iA', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '<leader>iR', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '<leader>il', { buffer = bufnr })
  pcall(vim.keymap.del, 'n', '<leader>iq', { buffer = bufnr })

  -- Clean up state
  M.active_diffs[bufnr] = nil


  -- Check if all diffs are closed
  local has_active_diffs = false
  for _, diff in pairs(M.active_diffs) do
    if diff then
      has_active_diffs = true
      break
    end
  end

  -- Also check if there are still Claude-edited files that haven't been opened yet
  local hooks = require 'nvim-claude.hooks'
  local has_tracked_files = false
  for _, tracked in pairs(hooks.claude_edited_files) do
    if tracked then
      has_tracked_files = true
      break
    end
  end

  -- Only clear everything if no active diffs AND no tracked files
  if not has_active_diffs and not has_tracked_files then
    local persistence = require 'nvim-claude.inline-diff-persistence'
    persistence.clear_state()
    persistence.current_stash_ref = nil

    -- Reset the stable baseline in hooks
    hooks.stable_baseline_ref = nil
    hooks.claude_edited_files = {}
  end

  vim.notify('Inline diff closed', vim.log.levels.INFO)
end

-- Check if buffer has active inline diff
function M.has_active_diff(bufnr)
  return M.active_diffs[bufnr] ~= nil
end

-- Update baseline content after accepting a hunk (deprecated - no longer creates commits)
function M.update_baseline_after_accept(bufnr, hunk)
  -- This function is deprecated but kept for compatibility
  -- The baseline update is now handled directly in accept_current_hunk
end

-- Test keymap functionality (commented out for release)
-- function M.test_keymap()
--   local bufnr = vim.api.nvim_get_current_buf()
--   vim.notify('Testing keymap for buffer: ' .. bufnr, vim.log.levels.INFO)
--   vim.notify('Available diff data: ' .. vim.inspect(vim.tbl_keys(M.active_diffs)), vim.log.levels.INFO)
--
--   if M.active_diffs[bufnr] then
--     vim.notify('Diff data found! Calling reject function...', vim.log.levels.INFO)
--     M.reject_current_hunk(bufnr)
--   else
--     vim.notify('No diff data for this buffer', vim.log.levels.ERROR)
--   end
-- end

-- Navigate to next file with diff
function M.next_diff_file()
  local current_file = vim.api.nvim_buf_get_name(0)
  local files_with_diffs = {}
  local hooks = require 'nvim-claude.hooks'

  -- Collect all files with diffs
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()

  for relative_path, _ in pairs(hooks.claude_edited_files) do
    local full_path = git_root .. '/' .. relative_path
    table.insert(files_with_diffs, full_path)
  end

  if #files_with_diffs == 0 then
    vim.notify('No files with active diffs', vim.log.levels.INFO)
    return
  end

  -- Sort files for consistent navigation
  table.sort(files_with_diffs)

  -- Find current file index
  local current_idx = 0
  for i, file_path in ipairs(files_with_diffs) do
    if file_path == current_file then
      current_idx = i
      break
    end
  end

  -- Go to next file (wrap around)
  local next_idx = current_idx + 1
  if next_idx > #files_with_diffs then
    next_idx = 1
  end

  local next_file = files_with_diffs[next_idx]
  vim.cmd('edit ' .. vim.fn.fnameescape(next_file))
  vim.notify(string.format('Diff file %d/%d: %s', next_idx, #files_with_diffs, vim.fn.fnamemodify(next_file, ':t')), vim.log.levels.INFO)
end

-- Navigate to previous file with diff
function M.prev_diff_file()
  local current_file = vim.api.nvim_buf_get_name(0)
  local files_with_diffs = {}
  local hooks = require 'nvim-claude.hooks'

  -- Collect all files with diffs
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()

  for relative_path, _ in pairs(hooks.claude_edited_files) do
    local full_path = git_root .. '/' .. relative_path
    table.insert(files_with_diffs, full_path)
  end

  if #files_with_diffs == 0 then
    vim.notify('No files with active diffs', vim.log.levels.INFO)
    return
  end

  -- Sort files for consistent navigation
  table.sort(files_with_diffs)

  -- Find current file index
  local current_idx = 0
  for i, file_path in ipairs(files_with_diffs) do
    if file_path == current_file then
      current_idx = i
      break
    end
  end

  -- Go to previous file (wrap around)
  local prev_idx = current_idx - 1
  if prev_idx < 1 then
    prev_idx = #files_with_diffs
  end

  local prev_file = files_with_diffs[prev_idx]
  vim.cmd('edit ' .. vim.fn.fnameescape(prev_file))
  vim.notify(string.format('Diff file %d/%d: %s', prev_idx, #files_with_diffs, vim.fn.fnamemodify(prev_file, ':t')), vim.log.levels.INFO)
end

-- Manual refresh function
function M.refresh_inline_diff(bufnr)
  -- Save cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)

  -- Get current baseline
  local hooks = require 'nvim-claude.hooks'
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  local stash_ref = hooks.stable_baseline_ref or persistence.current_stash_ref
  if not stash_ref then
    -- Check if this file is Claude-tracked - only warn if it should have a baseline
    local git_root = utils.get_project_root()
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
    
    if hooks.claude_edited_files[relative_path] then
      -- This is a corrupted state - Claude-tracked file with no baseline
      vim.notify('No baseline found for Claude-tracked file', vim.log.levels.WARN)
    end
    return
  end

  local git_root = utils.get_project_root()
  if not git_root then
    return
  end

  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

  -- Get baseline content
  local baseline_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, stash_ref, relative_path)
  local baseline_content = utils.exec(baseline_cmd)
  if not baseline_content then
    baseline_content = '' -- New file
  end

  -- Get current buffer content
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')

  -- Preserve current hunk position
  local current_hunk = M.active_diffs[bufnr] and M.active_diffs[bufnr].current_hunk or 1

  -- Recompute and show diff
  M.show_inline_diff(bufnr, baseline_content, current_content)

  -- Restore hunk position if possible
  if M.active_diffs[bufnr] and M.active_diffs[bufnr].hunks then
    local hunk_count = #M.active_diffs[bufnr].hunks
    if current_hunk <= hunk_count then
      M.active_diffs[bufnr].current_hunk = current_hunk
    end
  end

  -- Restore cursor position
  vim.api.nvim_win_set_cursor(0, cursor_pos)

  vim.notify('Diff refreshed', vim.log.levels.INFO)
end

-- Set up auto-refresh on save
function M.setup_auto_refresh(bufnr)
  -- Create buffer-local autocmd group
  local group = vim.api.nvim_create_augroup('NvimClaudeAutoRefresh_' .. bufnr, { clear = true })

  -- Set up autocmd for save only
  vim.api.nvim_create_autocmd({ 'BufWritePost' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      -- Only refresh if this buffer has an active diff
      if M.active_diffs[bufnr] then
        M.refresh_inline_diff(bufnr)
      end
    end,
    desc = 'Refresh inline diff on save',
  })
end

-- List all files with active diffs
function M.list_diff_files()
  local files_with_diffs = {}
  local hooks = require 'nvim-claude.hooks'
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()

  for relative_path, _ in pairs(hooks.claude_edited_files) do
    local full_path = git_root .. '/' .. relative_path
    
    -- Check if we have an open buffer for this file
    local bufnr = vim.fn.bufnr(full_path)
    local diff_data = nil
    if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      diff_data = M.active_diffs[bufnr]
    end

    table.insert(files_with_diffs, {
      path = full_path,
      hunks = diff_data and #diff_data.hunks or '?',
      name = vim.fn.fnamemodify(full_path, ':t'),
      relative_path = relative_path,
      current_hunk = diff_data and diff_data.current_hunk or 1,
    })
  end

  if #files_with_diffs == 0 then
    vim.notify('No files with active diffs', vim.log.levels.INFO)
    return
  end

  -- Sort by filename
  table.sort(files_with_diffs, function(a, b)
    return a.name < b.name
  end)

  -- Create items for vim.ui.select
  local items = {}
  local display_items = {}

  for i, file_info in ipairs(files_with_diffs) do
    table.insert(items, file_info)
    local hunk_info = type(file_info.hunks) == 'number' and string.format('%d hunks, on hunk %d', file_info.hunks, file_info.current_hunk) or 'not opened yet'
    table.insert(display_items, string.format('%s (%s)', file_info.relative_path, hunk_info))
  end

  -- Use vim.ui.select for a telescope-like experience
  vim.ui.select(display_items, {
    prompt = 'Select file with Claude edits:',
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice and idx then
      local selected_file = items[idx]
      vim.cmd('edit ' .. vim.fn.fnameescape(selected_file.path))

      -- Jump to the current hunk in the selected file if it has an active diff
      local bufnr = vim.fn.bufnr(selected_file.path)
      if bufnr > 0 and M.active_diffs[bufnr] then
        M.jump_to_hunk(bufnr, M.active_diffs[bufnr].current_hunk)
      end
    end
  end)
end

-- Accept all diffs across all files
function M.accept_all_files()
  local hooks = require 'nvim-claude.hooks'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Count tracked files for reporting
  local cleared_count = vim.tbl_count(hooks.claude_edited_files)

  if cleared_count == 0 then
    vim.notify('No Claude edits to accept', vim.log.levels.INFO)
    return
  end

  -- Clear all visual diff displays from all buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  end

  -- Clear all diff state
  M.active_diffs = {}

  -- Clear all tracking
  hooks.claude_edited_files = {}
  hooks.stable_baseline_ref = nil

  -- Clear persistence
  persistence.clear_state()

  vim.notify(string.format('Accepted all changes from %d files', cleared_count), vim.log.levels.INFO)
end

-- Reject all diffs across all files
function M.reject_all_files()
  local hooks = require 'nvim-claude.hooks'
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Count tracked files for reporting
  local file_count = vim.tbl_count(hooks.claude_edited_files)

  if file_count == 0 then
    vim.notify('No Claude edits to reject', vim.log.levels.INFO)
    return
  end

  -- Get git root
  local git_root = utils.get_project_root()
  if not git_root then
    vim.notify('Not in a git repository', vim.log.levels.ERROR)
    return
  end

  -- Get baseline reference
  local baseline_ref = hooks.stable_baseline_ref
  if not baseline_ref then
    vim.notify('No baseline found to restore from', vim.log.levels.ERROR)
    return
  end

  -- Restore each Claude-edited file to baseline
  local restored_files = {}
  for relative_path, _ in pairs(hooks.claude_edited_files) do
    local full_path = git_root .. '/' .. relative_path

    -- Use git show to get the file content from baseline
    local cmd = string.format("cd '%s' && git show %s:'%s' > '%s'", git_root, baseline_ref, relative_path, full_path)
    local result, err = utils.exec(cmd)

    if not err then
      table.insert(restored_files, relative_path)
    else
      -- File might not exist in baseline (new file), so delete it
      local delete_cmd = string.format('rm -f "%s"', full_path)
      utils.exec(delete_cmd)
      table.insert(restored_files, relative_path .. ' (deleted)')
    end
  end

  -- Clear all visual diff displays from all buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  end

  -- Clear all diff state
  M.active_diffs = {}

  -- Clear all tracking
  hooks.claude_edited_files = {}
  hooks.stable_baseline_ref = nil

  -- Clear persistence completely for consistency with accept all
  persistence.clear_state()

  -- Refresh all buffers
  vim.cmd 'checktime'

  vim.notify(string.format('Rejected all Claude changes in %d files', file_count), vim.log.levels.INFO)
end

return M
