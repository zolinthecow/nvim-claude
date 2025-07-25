-- Claude Code hooks integration for nvim-claude
local M = {}

-- Track hook state
M.pre_edit_commit = nil
-- Baseline reference now managed by persistence module (persistence.current_stash_ref)
M.claude_edited_files = {} -- Track which files Claude has edited

-- Logger for debugging
local logger = require 'nvim-claude.logger'

-- Update stable baseline after accepting changes
function M.update_stable_baseline()
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Create a new baseline with current state
  local message = 'nvim-claude-baseline-accepted-' .. os.time()
  local baseline_ref = persistence.create_baseline(message)

  if baseline_ref then
    -- Update baseline reference (already done by create_baseline but be explicit)
    persistence.set_baseline_ref(baseline_ref)

    -- Save the updated state
    persistence.save_state { stash_ref = baseline_ref }
  end
end

function M.setup()
  -- Setup persistence layer on startup
  vim.defer_fn(function()
    M.setup_persistence()
  end, 500)

  -- Set up autocmd for opening files
  M.setup_file_open_autocmd()
end

-- Pre-tool-use hook: Create baseline stash if we don't have one
function M.pre_tool_use_hook_test()
  -- Simple debug: Write to a global variable first
  _G.NVIM_CLAUDE_PRE_HOOK_CALLED = os.time()
  _G.NVIM_CLAUDE_PRE_HOOK_COUNT = (_G.NVIM_CLAUDE_PRE_HOOK_COUNT or 0) + 1

  -- Also try vim.notify to see if it shows up
  local msg = string.format('PRE-HOOK CALLED! Count: %d, Time: %s', _G.NVIM_CLAUDE_PRE_HOOK_COUNT, os.date '%H:%M:%S')
  vim.notify(msg, vim.log.levels.WARN)

  -- For now, just return true without doing anything else
  return true
end

-- Per-file baseline management pre-hook
function M.pre_tool_use_hook(file_path)
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'


  logger.info('pre_tool_use_hook', 'Called with file_path: ' .. (file_path or 'nil'), {
    stable_baseline_ref = persistence.get_baseline_ref(),
    claude_edited_files_count = vim.tbl_count(M.claude_edited_files),
  })

  -- If no file path provided, fall back to old behavior
  if not file_path then
    logger.warn('pre_tool_use_hook', 'No file path provided, using legacy behavior')
    return M.legacy_pre_tool_use_hook()
  end

  local git_root = utils.get_project_root_for_file(file_path)
  if not git_root then
    logger.error('pre_tool_use_hook', 'No git root found for file: ' .. file_path)
    return true
  end

  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  logger.debug('pre_tool_use_hook', 'Git root and relative path', {
    git_root = git_root,
    relative_path = relative_path,
  })

  -- Case 1: No baseline exists at all → create full baseline
  if not persistence.get_baseline_ref() then
    logger.info('pre_tool_use_hook', 'No baseline exists, creating new baseline')
    local baseline_ref = persistence.create_baseline('nvim-claude: baseline ' .. os.date '%Y-%m-%d %H:%M:%S')
    if baseline_ref then
      -- Check for error messages in baseline_ref
      if baseline_ref:match 'fatal:' or baseline_ref:match 'error:' then
        logger.error('pre_tool_use_hook', 'Got error when creating baseline', {
          baseline_ref = baseline_ref,
          cwd = vim.fn.getcwd(),
        })
        return true
      end

      persistence.set_baseline_ref(baseline_ref)
      logger.info('pre_tool_use_hook', 'Created baseline', { baseline_ref = baseline_ref })

      -- IMPORTANT: Save state immediately to handle multiple Neovim instances
      persistence.save_state {
        stash_ref = baseline_ref,
        claude_edited_files = M.claude_edited_files,
      }
    else
      logger.error('pre_tool_use_hook', 'Failed to create baseline')
    end

  -- Case 2: File already Claude-edited → do nothing (baseline already captured)
  elseif M.claude_edited_files[relative_path] then
    logger.debug('pre_tool_use_hook', 'File already tracked as Claude-edited: ' .. relative_path)

  -- Case 3: New file for Claude to edit → update baseline for this specific file
  else
    -- Check if file exists before updating baseline
    local full_path = git_root .. '/' .. relative_path
    if utils.file_exists(full_path) then
      logger.info('pre_tool_use_hook', 'Updating baseline for new file: ' .. relative_path)
      M.update_baseline_for_file(relative_path, git_root)
    else
      logger.debug('pre_tool_use_hook', 'File does not exist yet: ' .. full_path)
    end
  end

  return true
end

-- Legacy pre-hook for backward compatibility
function M.legacy_pre_tool_use_hook()
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Only create a baseline if we don't have one yet
  if not persistence.get_baseline_ref() then
    local stash_ref = persistence.create_baseline('nvim-claude: baseline ' .. os.date '%Y-%m-%d %H:%M:%S')
    if stash_ref then
      persistence.set_baseline_ref(stash_ref)

      -- IMPORTANT: Save state immediately to handle multiple Neovim instances
      persistence.save_state {
        stash_ref = stash_ref,
        claude_edited_files = M.claude_edited_files or {},
      }
    end
  end

  return true
end

-- Update baseline stash to include current state of a specific file
function M.update_baseline_for_file(relative_path, git_root)
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Check if file exists on disk
  local full_path = git_root .. '/' .. relative_path
  if not utils.file_exists(full_path) then
    return
  end

  -- Read current file content
  local current_content = utils.read_file(full_path)
  if not current_content then
    return
  end

  -- Use simpler approach with temporary index
  local temp_dir = '/tmp/nvim-claude-baseline-' .. os.time() .. '-' .. math.random(10000)
  local success = pcall(function()
    -- Create temporary directory
    vim.fn.mkdir(temp_dir, 'p')

    -- Set up temporary index file
    local temp_index = temp_dir .. '/index'

    -- Read the tree from current baseline into temporary index
    local read_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git read-tree %s', git_root, temp_index, persistence.get_baseline_ref())
    local read_result, read_err = utils.exec(read_tree_cmd)
    if read_err then
      error('Failed to read baseline tree: ' .. read_err)
    end

    -- Write content to temporary file
    local temp_file = temp_dir .. '/content'
    utils.write_file(temp_file, current_content)

    -- Update the specific file in the temporary index
    local update_cmd = string.format(
      'cd "%s" && GIT_INDEX_FILE="%s" git update-index --add --cacheinfo 100644,$(git hash-object -w "%s"),"%s"',
      git_root,
      temp_index,
      temp_file,
      relative_path
    )
    local update_result, update_err = utils.exec(update_cmd)
    if update_err then
      error('Failed to update file in index: ' .. update_err)
    end

    -- Create tree from temporary index
    local write_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
    local new_tree_hash, tree_err = utils.exec(write_tree_cmd)
    if tree_err or not new_tree_hash then
      error('Failed to write tree: ' .. (tree_err or 'unknown error'))
    end
    new_tree_hash = new_tree_hash:gsub('%s+$', '')

    -- Create new commit
    local commit_message = string.format('nvim-claude: updated baseline for %s at %s', relative_path, os.date '%Y-%m-%d %H:%M:%S')
    local commit_cmd = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', git_root, new_tree_hash, persistence.get_baseline_ref(), commit_message)
    local new_commit_hash, commit_err = utils.exec(commit_cmd)
    if commit_err or not new_commit_hash then
      error('Failed to create commit: ' .. (commit_err or 'unknown error'))
    end
    new_commit_hash = new_commit_hash:gsub('%s+$', '')

    -- Cleanup is done after pcall

    -- Validate before updating baseline reference
    if new_commit_hash:match 'fatal:' or new_commit_hash:match 'error:' then
      error('Got error message instead of commit hash: ' .. new_commit_hash)
    end

    -- Update our baseline reference to the new commit
    persistence.set_baseline_ref(new_commit_hash)
    persistence.current_stash_ref = new_commit_hash

    -- Save persistence state
    persistence.save_state {
      stash_ref = new_commit_hash,
      claude_edited_files = M.claude_edited_files,
    }
  end)

  -- Clean up temp directory
  if vim.fn.isdirectory(temp_dir) == 1 then
    vim.fn.delete(temp_dir, 'rf')
  end

  if not success then
    logger.error('update_baseline_for_file', 'Failed to update baseline')
  end
end

-- Session tracking for Stop hook
M.session_edited_files = {}

-- Post-tool-use hook: Track Claude-edited file and refresh if currently open
function M.post_tool_use_hook(file_path)
  if not file_path then
    logger.warn('post_tool_use_hook', 'Called with no file path')
    return
  end

  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  logger.info('post_tool_use_hook', 'Called with file_path: ' .. file_path, {
    stable_baseline_ref = persistence.get_baseline_ref(),
    claude_edited_files_count = vim.tbl_count(M.claude_edited_files),
  })
  local git_root = utils.get_project_root_for_file(file_path)

  if not git_root then
    logger.error('post_tool_use_hook', 'No git root found for file: ' .. file_path)
    return
  end

  -- Track this file as Claude-edited
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  M.claude_edited_files[relative_path] = true
  logger.info('post_tool_use_hook', 'Marked file as Claude-edited: ' .. relative_path)

  -- Also track for session (Stop hook)
  M.session_edited_files[relative_path] = true

  -- Check if we have a baseline before saving
  if not persistence.get_baseline_ref() then
    logger.error('post_tool_use_hook', 'No baseline ref when saving state!', {
      relative_path = relative_path,
      persistence_stash_ref = persistence.current_stash_ref,
    })
  end

  -- Save to persistence
  persistence.save_state {
    stash_ref = persistence.get_baseline_ref(),
    claude_edited_files = M.claude_edited_files,
  }
  logger.debug('post_tool_use_hook', 'Saved state to persistence')

  -- If this file is currently open in a buffer, refresh it and show diff
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == file_path then
        -- Refresh the buffer to show Claude's changes
        vim.api.nvim_buf_call(buf, function()
          vim.cmd 'checktime'
        end)

        -- Show inline diff if we have a baseline (with delay for buffer refresh)
        if persistence.get_baseline_ref() then
          -- Save cursor position before showing diff
          local cursor_pos = nil
          local win = vim.fn.bufwinid(buf)
          if win ~= -1 then
            cursor_pos = vim.api.nvim_win_get_cursor(win)
          end
          
          vim.defer_fn(function()
            M.show_inline_diff_for_file(buf, relative_path, git_root, persistence.get_baseline_ref(), true)
            
            -- Restore cursor position if we saved it
            if cursor_pos then
              local current_win = vim.fn.bufwinid(buf)
              if current_win ~= -1 then
                pcall(vim.api.nvim_win_set_cursor, current_win, cursor_pos)
              end
            end
          end, 100)
        end
        break
      end
    end
  end
end

-- Track a file deletion (called from bash hook wrapper)
function M.track_deleted_file(file_path)
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'
  
  -- Get git root
  local git_root = utils.get_project_root()
  if not git_root then
    return false
  end
  
  -- Convert to relative path
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  logger.info('track_deleted_file', 'Tracking deleted file', {
    file_path = file_path,
    relative_path = relative_path,
  })
  
  -- Always create or update baseline before deletion to ensure we capture the file's state
  local baseline_ref = persistence.get_baseline_ref()
  if not baseline_ref then
    logger.info('track_deleted_file', 'No baseline exists, creating one')
    local new_baseline = persistence.create_baseline('Baseline for deletion tracking')
    if new_baseline then
      baseline_ref = new_baseline
      logger.info('track_deleted_file', 'Created baseline', { baseline_ref = baseline_ref })
    else
      logger.error('track_deleted_file', 'Failed to create baseline')
      return
    end
  else
    -- Baseline exists, but we should update it to include the current state of the file
    -- This ensures we capture the file content right before deletion
    logger.info('track_deleted_file', 'Updating baseline before deletion', { file = relative_path })
    M.update_baseline_for_file(relative_path, git_root)
    -- Get the updated baseline ref
    baseline_ref = persistence.get_baseline_ref()
  end
  
  -- Check if file exists in baseline
  if baseline_ref then
    local check_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, baseline_ref, relative_path)
    local baseline_content, err = utils.exec(check_cmd)
    
    if not err and baseline_content and not baseline_content:match('^fatal:') then
      -- File exists in baseline, track it as edited
      M.claude_edited_files[relative_path] = true
      M.session_edited_files[relative_path] = true
      
      -- Save to persistence
      persistence.save_state {
        stash_ref = baseline_ref,
        claude_edited_files = M.claude_edited_files,
      }
      
      logger.info('track_deleted_file', 'File tracked as deleted', {
        relative_path = relative_path,
        had_baseline = true,
      })
    else
      logger.info('track_deleted_file', 'File not in baseline, not tracking', {
        relative_path = relative_path,
      })
    end
  end
  
  return true  -- Return true so nvr doesn't complain
end

-- Untrack a file whose deletion failed (called from bash post-hook)
function M.untrack_failed_deletion(file_path)
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'
  
  -- Get git root
  local git_root = utils.get_project_root()
  if not git_root then
    return false
  end
  
  -- Convert to relative path
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  logger.info('untrack_failed_deletion', 'Untracking file whose deletion failed', {
    file_path = file_path,
    relative_path = relative_path,
  })
  
  -- Remove from tracking if it was tracked
  if M.claude_edited_files[relative_path] then
    M.claude_edited_files[relative_path] = nil
    
    -- Save updated state
    persistence.save_state({
      stash_ref = persistence.get_baseline_ref(),
      claude_edited_files = M.claude_edited_files
    })
    
    logger.info('untrack_failed_deletion', 'File untracked', {
      relative_path = relative_path,
    })
  end
  
  return true
end

-- Helper function to show inline diff for a file
function M.show_inline_diff_for_file(buf, file, git_root, stash_ref, preserve_cursor)
  local utils = require 'nvim-claude.utils'
  local inline_diff = require 'nvim-claude.inline-diff'

  -- Only show inline diff if Claude edited this file
  if not M.claude_edited_files[file] then
    return false
  end

  -- Validate stash reference before using it
  if not stash_ref or stash_ref == '' then
    vim.notify('No baseline stash reference found for ' .. file, vim.log.levels.WARN)
    return false
  end

  -- Get baseline from git stash
  local stash_cmd = string.format("cd '%s' && git show %s:'%s' 2>/dev/null", git_root, stash_ref, file)
  logger.info('show_inline_diff_for_file', 'Executing git show command', {
    git_root = git_root,
    stash_ref = stash_ref,
    file = file,
    command = stash_cmd
  })
  local original_content, git_err = utils.exec(stash_cmd)

  -- If file doesn't exist in baseline, treat as new file (empty baseline)
  -- Check for git error messages that indicate file doesn't exist in stash
  if git_err or not original_content or original_content:match('^fatal:') or original_content:match('^error:') then
    logger.warn('show_inline_diff_for_file', 'Failed to get baseline content', {
      git_err = git_err,
      original_content = original_content,
      file = file
    })
    original_content = ''
  end

  -- Get current content
  local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')

  -- Show inline diff (empty baseline will show entire file as additions)
  local opts = preserve_cursor and { preserve_cursor = true } or {}
  inline_diff.show_inline_diff(buf, original_content, current_content, opts)
  return true
end

-- Show diff for a deleted file
function M.show_deleted_file_diff(file_path, git_root, baseline_ref)
  local inline_diff = require 'nvim-claude.inline-diff'
  local utils = require 'nvim-claude.utils'
  local logger = require 'nvim-claude.logger'
  
  logger.info('show_deleted_file_diff', 'Showing diff for deleted file', { file = file_path })
  
  -- Get the relative path
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  -- Get baseline content
  local cmd = string.format("cd '%s' && git show %s:'%s' 2>&1", git_root, baseline_ref, relative_path)
  local original_content, git_err = utils.exec(cmd)
  
  -- Check for git error messages
  if git_err or not original_content or original_content:match('^fatal:') or original_content:match('^error:') then
    logger.warn('show_deleted_file_diff', 'Failed to get baseline content for deleted file', {
      git_err = git_err,
      original_content = original_content,
      file = relative_path
    })
    vim.notify('Failed to get baseline content for deleted file: ' .. relative_path, vim.log.levels.ERROR)
    return false
  end
  
  -- Create a new buffer with the baseline content
  local buf = vim.api.nvim_create_buf(false, true) -- nofile, scratch buffer
  
  -- Set buffer options
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  
  -- Set the buffer name to show it's deleted
  vim.api.nvim_buf_set_name(buf, file_path .. ' [DELETED]')
  
  -- Set buffer lines to baseline content
  local lines = vim.split(original_content, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  
  -- Open the buffer in current window
  vim.api.nvim_set_current_buf(buf)
  
  -- Highlight all lines as deleted (red) using extmarks
  local line_count = vim.api.nvim_buf_line_count(buf)
  local ns_id = vim.api.nvim_create_namespace('nvim-claude-deleted')
  
  -- Get window width for padding
  local win_width = vim.api.nvim_win_get_width(0)
  
  for i = 0, line_count - 1 do
    local line_text = lines[i + 1] or ''
    local line_display_width = vim.fn.strdisplaywidth(line_text)
    local padding_needed = math.max(0, win_width - line_display_width)
    
    -- Highlight the entire line including EOL
    vim.api.nvim_buf_set_extmark(buf, ns_id, i, 0, {
      end_line = i + 1,
      end_col = 0,
      hl_group = 'DiffDelete',
      hl_eol = true,
      priority = 1000
    })
  end
  
  -- Add a sign to show it's deleted
  vim.fn.sign_define('NvimClaudeDeleted', { text = 'X', texthl = 'DiffDelete' })
  for i = 1, line_count do
    vim.fn.sign_place(0, 'nvim-claude-deleted', 'NvimClaudeDeleted', buf, { lnum = i })
  end
  
  -- Make buffer non-modifiable
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  
  -- Set up keymap to restore the file (reject deletion)
  vim.api.nvim_buf_set_keymap(buf, 'n', '<leader>ir', '', {
    callback = function()
      -- Restore the file by writing the baseline content
      vim.fn.mkdir(vim.fn.fnamemodify(file_path, ':h'), 'p')
      
      -- Get the content from the current buffer
      local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content_to_restore = table.concat(buf_lines, '\n')
      if content_to_restore ~= '' and not content_to_restore:match('\n$') then
        content_to_restore = content_to_restore .. '\n'
      end
      
      utils.write_file(file_path, content_to_restore)
      
      -- Remove from tracking
      M.claude_edited_files[relative_path] = nil
      local persistence = require('nvim-claude.inline-diff-persistence')
      persistence.save_state({
        stash_ref = persistence.get_baseline_ref(),
        claude_edited_files = M.claude_edited_files
      })
      
      -- Close the deleted file buffer and open the restored file
      local deleted_buf = vim.api.nvim_get_current_buf()
      -- First open the restored file
      vim.cmd('edit ' .. vim.fn.fnameescape(file_path))
      -- Then delete the old buffer (if it still exists and is valid)
      if vim.api.nvim_buf_is_valid(deleted_buf) then
        vim.api.nvim_buf_delete(deleted_buf, { force = true })
      end
      
      vim.notify('File restored: ' .. relative_path, vim.log.levels.INFO)
    end,
    desc = 'Restore deleted file (reject deletion)',
    noremap = true,
    silent = true
  })
  
  -- Set up keymap to accept the deletion
  vim.api.nvim_buf_set_keymap(buf, 'n', '<leader>ia', '', {
    callback = function()
      -- Accept deletion - just remove from tracking
      M.claude_edited_files[relative_path] = nil
      local persistence = require('nvim-claude.inline-diff-persistence')
      persistence.save_state({
        stash_ref = persistence.get_baseline_ref(),
        claude_edited_files = M.claude_edited_files
      })
      
      -- Close the buffer
      local current_buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_delete(current_buf, { force = true })
      
      vim.notify('Deletion accepted for: ' .. relative_path, vim.log.levels.INFO)
    end,
    desc = 'Accept file deletion',
    noremap = true,
    silent = true
  })
  
  -- Also support <leader>iA and <leader>IA for consistency
  vim.api.nvim_buf_set_keymap(buf, 'n', '<leader>iA', '', {
    callback = function()
      vim.cmd('normal! \\<leader>ia')
    end,
    desc = 'Accept file deletion',
    noremap = true,
    silent = true
  })
  
  vim.api.nvim_buf_set_keymap(buf, 'n', '<leader>IA', '', {
    callback = function()
      vim.cmd('normal! \\<leader>ia')
    end,
    desc = 'Accept file deletion',
    noremap = true,
    silent = true
  })
  
  -- Show help message
  vim.notify('File was deleted. Press <leader>ia to accept deletion or <leader>ir to restore.', vim.log.levels.WARN)
  
  return true
end

-- Set up autocmd to check for diffs when opening files
function M.setup_file_open_autocmd()
  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    pattern = '*',
    callback = function(args)
      local bufnr = args.buf
      local file_path = vim.api.nvim_buf_get_name(bufnr)

      if file_path == '' then
        return
      end

      local utils = require 'nvim-claude.utils'
      local git_root = utils.get_project_root()

      if not git_root then
        return
      end

      -- Get relative path
      local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
      
      -- Require persistence module
      local persistence = require 'nvim-claude.inline-diff-persistence'

      -- Check if this file was edited by Claude
      if M.claude_edited_files[relative_path] and persistence.get_baseline_ref() then
        -- Show inline diff for this file
        vim.defer_fn(function()
          M.show_inline_diff_for_file(bufnr, relative_path, git_root, persistence.get_baseline_ref())
        end, 50) -- Small delay to ensure buffer is fully loaded
      else
        -- Check persistence state for tracked files
        if persistence.current_stash_ref then
          -- Check if we have persistence state but haven't restored claude_edited_files yet
          local state = persistence.load_state()
          if state and state.claude_edited_files and state.claude_edited_files[relative_path] then
            -- File is tracked in persistence, show diff
            persistence.set_baseline_ref(persistence.get_baseline_ref() or state.stash_ref)
            M.claude_edited_files[relative_path] = true
            vim.defer_fn(function()
              M.show_inline_diff_for_file(bufnr, relative_path, git_root, persistence.get_baseline_ref())
            end, 50)
          end
        end
      end
    end,
    group = vim.api.nvim_create_augroup('NvimClaudeFileOpen', { clear = true }),
  })
end

-- Setup persistence and restore saved state on Neovim startup
function M.setup_persistence()
  local persistence = require 'nvim-claude.inline-diff-persistence'

  logger.info('setup_persistence', 'Setting up persistence layer')

  -- Setup persistence autocmds
  persistence.setup_autocmds()

  -- Try to restore any saved diffs
  local restored = persistence.restore_diffs()
  logger.info('setup_persistence', 'Restored diffs', { restored = restored })

  -- Also restore the baseline reference from persistence if it exists
  if persistence.current_stash_ref then
    -- Baseline ref already loaded by persistence module
    logger.info('setup_persistence', 'Restored baseline ref from persistence', {
      stash_ref = persistence.get_baseline_ref(),
    })
  else
    logger.debug('setup_persistence', 'No baseline ref in persistence')
  end

  -- Don't create a startup baseline - only create baselines when Claude makes edits
end

-- Install Claude Code hooks
function M.install_hooks()
  local utils = require 'nvim-claude.utils'

  -- Get project root
  local project_root = utils.get_project_root()
  if not project_root then
    vim.notify('Not in a git repository', vim.log.levels.ERROR)
    return
  end

  -- Create .claude directory
  local claude_dir = project_root .. '/.claude'
  if not vim.fn.isdirectory(claude_dir) then
    vim.fn.mkdir(claude_dir, 'p')
  end

  -- Create hooks configuration using proxy scripts
  local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
  -- Use a simpler command that doesn't require complex quoting
  local pre_command = plugin_dir .. '/scripts/pre-hook-wrapper.sh'
  local post_command = plugin_dir .. '/scripts/post-hook-wrapper.sh'
  local stop_command = plugin_dir .. '/scripts/stop-hook-validator.sh'
  local bash_command = plugin_dir .. '/scripts/bash-hook-wrapper.sh'
  local bash_post_command = plugin_dir .. '/scripts/bash-post-hook-wrapper.sh'

  -- We'll merge these hooks into existing configuration

  -- Read existing settings.local.json if it exists
  local settings_file = claude_dir .. '/settings.local.json'
  local existing_settings = {}

  if utils.file_exists(settings_file) then
    existing_settings = utils.read_json(settings_file) or {}
  end

  -- Ensure hooks structure exists
  existing_settings.hooks = existing_settings.hooks or {}
  existing_settings.hooks.PreToolUse = existing_settings.hooks.PreToolUse or {}
  existing_settings.hooks.PostToolUse = existing_settings.hooks.PostToolUse or {}
  existing_settings.hooks.Stop = existing_settings.hooks.Stop or {}

  -- Helper function to add hook to a specific tool use section
  local function add_hook_to_section(section, command, matcher)
    local hook = {
      type = 'command',
      command = command,
    }

    if matcher then
      -- For PreToolUse/PostToolUse - need matcher
      -- Find existing matcher or create new one
      local matcher_found = false
      for i, entry in ipairs(section) do
        if entry.matcher == matcher then
          matcher_found = true
          -- Ensure hooks array exists
          entry.hooks = entry.hooks or {}

          -- Check if our hook already exists
          local hook_exists = false
          for _, existing_hook in ipairs(entry.hooks) do
            if existing_hook.command == command then
              hook_exists = true
              break
            end
          end

          -- Add hook if it doesn't exist
          if not hook_exists then
            table.insert(entry.hooks, hook)
          end
          break
        end
      end

      -- If matcher wasn't found, create new entry
      if not matcher_found then
        table.insert(section, {
          matcher = matcher,
          hooks = { hook },
        })
      end
    else
      -- For Stop hooks - need to wrap in hooks array
      -- Check if our hook already exists in any entry
      local hook_exists = false
      for _, entry in ipairs(section) do
        if entry.hooks then
          for _, existing_hook in ipairs(entry.hooks) do
            if existing_hook.command == command then
              hook_exists = true
              break
            end
          end
        end
        if hook_exists then
          break
        end
      end

      -- Add hook if it doesn't exist
      if not hook_exists then
        table.insert(section, {
          hooks = { hook },
        })
      end
    end
  end

  -- Add our hooks
  add_hook_to_section(existing_settings.hooks.PreToolUse, pre_command, 'Edit|Write|MultiEdit')
  add_hook_to_section(existing_settings.hooks.PostToolUse, post_command, 'Edit|Write|MultiEdit')
  add_hook_to_section(existing_settings.hooks.PreToolUse, bash_command, 'Bash')
  add_hook_to_section(existing_settings.hooks.PostToolUse, bash_post_command, 'Bash')
  add_hook_to_section(existing_settings.hooks.Stop, stop_command, nil)

  -- Write merged configuration
  local success, err = utils.write_json(settings_file, existing_settings)

  if success then
    -- Add entries to gitignore if needed
    local gitignore_path = project_root .. '/.gitignore'
    local gitignore_content = utils.read_file(gitignore_path) or ''

    local entries_to_add = {}

    -- Check for .claude/settings.local.json
    if not gitignore_content:match '%.claude/settings%.local%.json' then
      table.insert(entries_to_add, '.claude/settings.local.json')
    end

    -- Check for .nvim-claude/
    if not gitignore_content:match '%.nvim%-claude/' then
      table.insert(entries_to_add, '.nvim-claude/')
    end

    -- Add entries if needed
    if #entries_to_add > 0 then
      local new_content = gitignore_content .. '\n# nvim-claude\n' .. table.concat(entries_to_add, '\n') .. '\n'
      utils.write_file(gitignore_path, new_content)
      vim.notify('Added ' .. table.concat(entries_to_add, ', ') .. ' to .gitignore', vim.log.levels.INFO)
    end

    vim.notify('Claude Code hooks installed successfully', vim.log.levels.INFO)
  else
    vim.notify('Failed to install hooks: ' .. (err or 'unknown error'), vim.log.levels.ERROR)
  end
end

-- Uninstall Claude Code hooks
function M.uninstall_hooks()
  local utils = require 'nvim-claude.utils'

  -- Get project root
  local project_root = utils.get_project_root()
  if not project_root then
    vim.notify('Not in a git repository', vim.log.levels.ERROR)
    return
  end

  local settings_file = project_root .. '/.claude/settings.local.json'

  if vim.fn.filereadable(settings_file) == 1 then
    -- Read existing settings
    local existing_settings = utils.read_json(settings_file) or {}

    if existing_settings.hooks then
      local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
      local pre_command = plugin_dir .. '/scripts/pre-hook-wrapper.sh'
      local post_command = plugin_dir .. '/scripts/post-hook-wrapper.sh'
      local stop_command = plugin_dir .. '/scripts/stop-hook-validator.sh'
      local hooks_removed = false

      -- Helper function to remove our hooks from a section
      local function remove_hooks_from_section(section, command, has_matcher)
        if not section then
          return false
        end

        local removed = false

        if has_matcher then
          -- PreToolUse/PostToolUse with matchers
          for i = #section, 1, -1 do
            local entry = section[i]
            if entry.matcher == 'Edit|Write|MultiEdit' and entry.hooks then
              -- Remove our specific hook
              for j = #entry.hooks, 1, -1 do
                if entry.hooks[j].command == command then
                  table.remove(entry.hooks, j)
                  removed = true
                end
              end

              -- Remove entry if no hooks left
              if #entry.hooks == 0 then
                table.remove(section, i)
              end
            end
          end
        else
          -- Stop hooks - need to check inside hooks arrays
          for i = #section, 1, -1 do
            local entry = section[i]
            if entry.hooks then
              -- Remove our specific hook from the hooks array
              for j = #entry.hooks, 1, -1 do
                if entry.hooks[j].command == command then
                  table.remove(entry.hooks, j)
                  removed = true
                end
              end

              -- Remove entry if no hooks left
              if #entry.hooks == 0 then
                table.remove(section, i)
              end
            end
          end
        end

        return removed
      end

      -- Remove from PreToolUse
      if existing_settings.hooks.PreToolUse then
        if remove_hooks_from_section(existing_settings.hooks.PreToolUse, pre_command, true) then
          hooks_removed = true
        end

        -- Clean up empty PreToolUse
        if #existing_settings.hooks.PreToolUse == 0 then
          existing_settings.hooks.PreToolUse = nil
        end
      end

      -- Remove from PostToolUse
      if existing_settings.hooks.PostToolUse then
        if remove_hooks_from_section(existing_settings.hooks.PostToolUse, post_command, true) then
          hooks_removed = true
        end

        -- Clean up empty PostToolUse
        if #existing_settings.hooks.PostToolUse == 0 then
          existing_settings.hooks.PostToolUse = nil
        end
      end

      -- Remove from Stop
      if existing_settings.hooks.Stop then
        if remove_hooks_from_section(existing_settings.hooks.Stop, stop_command, false) then
          hooks_removed = true
        end

        -- Clean up empty Stop
        if #existing_settings.hooks.Stop == 0 then
          existing_settings.hooks.Stop = nil
        end
      end

      -- Clean up empty hooks section
      if not existing_settings.hooks.PreToolUse and not existing_settings.hooks.PostToolUse and not existing_settings.hooks.Stop then
        existing_settings.hooks = nil
      end

      -- Save or delete file
      if next(existing_settings) then
        -- Still has other settings, write them back
        utils.write_json(settings_file, existing_settings)
      else
        -- No other settings, delete the file
        vim.fn.delete(settings_file)
      end

      if hooks_removed then
        vim.notify('Claude Code hooks uninstalled', vim.log.levels.INFO)
      else
        vim.notify('No nvim-claude hooks found', vim.log.levels.INFO)
      end
    else
      vim.notify('No hooks configuration found', vim.log.levels.INFO)
    end
  else
    vim.notify('No hooks configuration found', vim.log.levels.INFO)
  end
end

-- Commands for manual hook management
function M.setup_commands()
  vim.api.nvim_create_user_command('ClaudeDebugInlineDiff', function()
    require('nvim-claude.inline-diff-debug').debug_inline_diff()
  end, {
    desc = 'Debug Claude inline diff state',
  })

  vim.api.nvim_create_user_command('ClaudeResetInlineDiff', function()
    local inline_diff = require 'nvim-claude.inline-diff'
    local persistence = require 'nvim-claude.inline-diff-persistence'

    -- Check for corrupted state
    local corrupted = false
    local baseline_ref = persistence.get_baseline_ref()
    if baseline_ref and (baseline_ref:match 'fatal:' or baseline_ref:match 'error:') then
      vim.notify('Detected corrupted baseline ref: ' .. baseline_ref:sub(1, 50) .. '...', vim.log.levels.WARN)
      corrupted = true
    end

    if persistence.current_stash_ref and (persistence.current_stash_ref:match 'fatal:' or persistence.current_stash_ref:match 'error:') then
      vim.notify('Detected corrupted stash ref: ' .. persistence.current_stash_ref:sub(1, 50) .. '...', vim.log.levels.WARN)
      corrupted = true
    end

    if not corrupted then
      -- Check if state file exists
      local state_file = persistence.get_state_file()
      local utils = require 'nvim-claude.utils'
      if not utils.file_exists(state_file) then
        vim.notify('No inline diff state found to reset', vim.log.levels.INFO)
        return
      end
    end

    -- Confirm reset
    vim.ui.confirm('Reset inline diff state? This will clear all diff tracking.', { '&Yes', '&No' }, function(choice)
      if choice == 1 then
        -- Clear in-memory state
        persistence.set_baseline_ref(nil)
        M.claude_edited_files = {}
        persistence.current_stash_ref = nil

        -- Clear active diffs
        for bufnr, _ in pairs(inline_diff.active_diffs) do
          inline_diff.close_inline_diff(bufnr, true)
        end
        inline_diff.active_diffs = {}

        -- Clear persistence file
        persistence.clear_state()

        vim.notify('Inline diff state has been reset', vim.log.levels.INFO)
      end
    end)
  end, {
    desc = 'Reset inline diff state (use when corrupted)',
  })

  vim.api.nvim_create_user_command('ClaudeUpdateBaseline', function()
    -- This command is deprecated - baselines are now managed via git stashes
    vim.notify('ClaudeUpdateBaseline is deprecated. Use ClaudeAcceptAll to accept changes.', vim.log.levels.WARN)
  end, {
    desc = 'Update Claude baseline to current buffer state (deprecated)',
  })

  vim.api.nvim_create_user_command('ClaudeInstallHooks', function()
    M.install_hooks()
  end, {
    desc = 'Install Claude Code hooks for this project',
  })

  vim.api.nvim_create_user_command('ClaudeUninstallHooks', function()
    M.uninstall_hooks()
  end, {
    desc = 'Uninstall Claude Code hooks for this project',
  })

  vim.api.nvim_create_user_command('ClaudeResetBaseline', function()
    -- Clear all baselines and force new baseline on next edit
    local persistence = require 'nvim-claude.inline-diff-persistence'

    -- Clear stable baseline reference
    persistence.set_baseline_ref(nil)
    persistence.current_stash_ref = nil
    M.claude_edited_files = {}

    -- Clear persistence state
    persistence.clear_state()

    vim.notify('Baseline reset. Next edit will create a new baseline.', vim.log.levels.INFO)
  end, {
    desc = 'Reset Claude baseline for cumulative diffs',
  })

  vim.api.nvim_create_user_command('ClaudeAcceptAll', function()
    local inline_diff = require 'nvim-claude.inline-diff'
    inline_diff.accept_all_files()
  end, {
    desc = 'Accept all Claude diffs across all files',
  })

  vim.api.nvim_create_user_command('ClaudeTrackModified', function()
    -- Manually track all modified files as Claude-edited
    local utils = require 'nvim-claude.utils'
    local git_root = utils.get_project_root()

    if not git_root then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local status_cmd = string.format('cd "%s" && git status --porcelain', git_root)
    local status_result = utils.exec(status_cmd)

    if not status_result or status_result == '' then
      vim.notify('No modified files found', vim.log.levels.INFO)
      return
    end

    local count = 0
    for line in status_result:gmatch '[^\n]+' do
      local file = line:match '^.M (.+)$' or line:match '^M. (.+)$'
      if file then
        M.claude_edited_files[file] = true
        count = count + 1
      end
    end

    vim.notify(string.format('Tracked %d modified files as Claude-edited', count), vim.log.levels.INFO)

    -- Also ensure we have a baseline
    if not persistence.get_baseline_ref() then
      local persistence = require 'nvim-claude.inline-diff-persistence'
      local stash_list = utils.exec 'git stash list | grep "nvim-claude: baseline" | head -1'
      if stash_list and stash_list ~= '' then
        local stash_ref = stash_list:match '^(stash@{%d+})'
        if stash_ref then
          -- Get the SHA of this stash for stability
          local sha_cmd = string.format('git rev-parse %s', stash_ref)
          local stash_sha = utils.exec(sha_cmd)
          if stash_sha then
            stash_sha = stash_sha:gsub('%s+', '') -- trim whitespace
            persistence.set_baseline_ref(stash_sha)
            persistence.current_stash_ref = stash_sha
            vim.notify('Using baseline: ' .. stash_sha .. ' (from ' .. stash_ref .. ')', vim.log.levels.INFO)
          end
        end
      end
    end
  end, {
    desc = 'Track all modified files as Claude-edited (for debugging)',
  })

  vim.api.nvim_create_user_command('ClaudeRestoreState', function()
    -- Manually restore the state
    local persistence = require 'nvim-claude.inline-diff-persistence'
    local restored = persistence.restore_diffs()

    if persistence.current_stash_ref then
      -- Baseline ref already loaded by persistence module
    end

    vim.notify('Manually restored state', vim.log.levels.INFO)
  end, {
    desc = 'Manually restore Claude diff state',
  })

  vim.api.nvim_create_user_command('ClaudeCleanStaleTracking', function()
    local utils = require 'nvim-claude.utils'
    local persistence = require 'nvim-claude.inline-diff-persistence'
    local git_root = utils.get_project_root()

    if not git_root or not persistence.get_baseline_ref() then
      vim.notify('No git root or baseline found', vim.log.levels.ERROR)
      return
    end

    local cleaned_count = 0
    local files_to_remove = {}

    -- Check each tracked file for actual differences
    for file_path, _ in pairs(M.claude_edited_files) do
      local diff_cmd = string.format('cd "%s" && git diff %s -- "%s" 2>/dev/null', git_root, persistence.get_baseline_ref(), file_path)
      local diff_output = utils.exec(diff_cmd)

      if not diff_output or diff_output == '' then
        -- No differences, remove from tracking
        table.insert(files_to_remove, file_path)
        cleaned_count = cleaned_count + 1
      end
    end

    -- Remove files with no differences
    for _, file_path in ipairs(files_to_remove) do
      M.claude_edited_files[file_path] = nil
    end

    -- Save updated state if we have a persistence stash ref
    if persistence.current_stash_ref then
      persistence.save_state { stash_ref = persistence.current_stash_ref }
    end

    vim.notify(string.format('Cleaned %d stale tracked files', cleaned_count), vim.log.levels.INFO)
  end, {
    desc = 'Clean up stale Claude file tracking',
  })

  vim.api.nvim_create_user_command('ClaudeUntrackFile', function()
    -- Remove current file from Claude tracking
    local utils = require 'nvim-claude.utils'
    local git_root = utils.get_project_root()

    if not git_root then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local file_path = vim.api.nvim_buf_get_name(0)
    local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')

    if M.claude_edited_files[relative_path] then
      M.claude_edited_files[relative_path] = nil
      vim.notify('Removed ' .. relative_path .. ' from Claude tracking', vim.log.levels.INFO)

      -- Also close any active inline diff for this buffer
      local inline_diff = require 'nvim-claude.inline-diff'
      local bufnr = vim.api.nvim_get_current_buf()
      if inline_diff.has_active_diff(bufnr) then
        inline_diff.close_inline_diff(bufnr)
      end
    else
      vim.notify(relative_path .. ' is not in Claude tracking', vim.log.levels.INFO)
    end
  end, {
    desc = 'Remove current file from Claude edited files tracking',
  })
end

-- Cleanup old temp files (no longer cleans up commits)
function M.cleanup_old_files()
  -- Clean up old temp files
  local temp_files = {
    '/tmp/claude-pre-edit-commit',
    '/tmp/claude-baseline-commit',
    '/tmp/claude-last-snapshot',
    '/tmp/claude-hook-test.log',
  }

  for _, file in ipairs(temp_files) do
    if vim.fn.filereadable(file) == 1 then
      vim.fn.delete(file)
    end
  end
end

-- Get diagnostic counts for session edited files (for Stop hook)
function M.get_session_diagnostic_counts()
  local counts = { errors = 0, warnings = 0 }

  -- Only check files edited in the current session
  local files_to_check = M.session_edited_files
  
  -- If no files were edited in this session, return early
  if vim.tbl_count(files_to_check) == 0 then
    logger.info('get_session_diagnostic_counts', 'No files edited in current session, skipping diagnostics')
    return '{"errors":0,"warnings":0}'
  end

  logger.info('get_session_diagnostic_counts', 'Checking files', vim.tbl_keys(files_to_check))

  for file_path, _ in pairs(files_to_check) do
    local full_path = vim.fn.getcwd() .. '/' .. file_path
    local bufnr = vim.fn.bufnr(full_path)

    -- If buffer doesn't exist, create it temporarily to get diagnostics
    if bufnr == -1 then
      -- Create buffer and load file
      bufnr = vim.fn.bufadd(full_path)
      vim.fn.bufload(bufnr)

      -- Trigger LSP attach by detecting filetype
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd 'filetype detect'
      end)

      -- Wait longer for LSP to process the file
      vim.wait(1000, function()
        -- Check if we have diagnostics yet
        local diags = vim.diagnostic.get(bufnr)
        return #diags > 0
      end)
    end

    logger.debug('get_session_diagnostic_counts', 'Checking file', {
      file_path = file_path,
      full_path = full_path,
      bufnr = bufnr,
    })

    if bufnr ~= -1 then
      local diagnostics = vim.diagnostic.get(bufnr)

      for _, diag in ipairs(diagnostics) do
        if diag.severity == vim.diagnostic.severity.ERROR then
          counts.errors = counts.errors + 1
        elseif diag.severity == vim.diagnostic.severity.WARN then
          counts.warnings = counts.warnings + 1
        end
      end
    end
  end

  logger.info('get_session_diagnostic_counts', 'Diagnostic counts', counts)
  -- Ensure we always return valid JSON string
  local ok, json = pcall(vim.json.encode, counts)
  if ok then
    return json
  else
    return '{"errors":0,"warnings":0}'
  end
end

-- Reset session tracking (called after successful Stop)
function M.reset_session_tracking()
  logger.info('reset_session_tracking', 'Clearing session edited files')
  M.session_edited_files = {}
end

return M
