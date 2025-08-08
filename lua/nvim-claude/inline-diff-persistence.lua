-- Persistence layer for inline diffs
-- Manages saving/loading diff state across neovim sessions without polluting git history
--
-- Clean Architecture:
-- - Only persists git stash SHA reference and tracked file list
-- - All diffs are computed fresh from git baseline vs current state
-- - No cached diff data or hunks

local M = {}
local utils = require 'nvim-claude.utils'
local logger = require 'nvim-claude.logger'

-- Get the current baseline reference
function M.get_baseline_ref()
  -- First check memory cache
  if M.current_stash_ref then
    return M.current_stash_ref
  end
  
  -- Then check git custom ref
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()
  if git_root then
    local ref_cmd = string.format('cd "%s" && git rev-parse refs/nvim-claude/baseline 2>/dev/null', git_root)
    local ref, err = utils.exec(ref_cmd)
    if ref and not err then
      ref = ref:gsub('%s+', '')
      if ref ~= '' and ref:match '^[a-f0-9]+$' then
        M.current_stash_ref = ref
        return ref
      end
    end
  end
  
  return nil
end

-- Set the baseline reference and update both memory and git ref
function M.set_baseline_ref(ref)
  M.current_stash_ref = ref
  
  -- Also update the git ref if we have a valid SHA
  if ref and ref:match '^[a-f0-9]+$' then
    local utils = require 'nvim-claude.utils'
    local git_root = utils.get_project_root()
    if git_root then
      local ref_cmd = string.format('cd "%s" && git update-ref refs/nvim-claude/baseline %s', git_root, ref)
      utils.exec(ref_cmd)
    end
  end
end

-- Clear baseline ref (both memory and git ref)
function M.clear_baseline_ref()
  M.current_stash_ref = nil
  
  local utils = require 'nvim-claude.utils'
  local git_root = utils.get_project_root()
  if git_root then
    local ref_cmd = string.format('cd "%s" && git update-ref -d refs/nvim-claude/baseline 2>/dev/null', git_root)
    utils.exec(ref_cmd)
  end
end

-- Get project-specific nvim-claude directory (DEPRECATED - kept for compatibility)
function M.get_nvim_claude_dir(file_path)
  -- This function is deprecated but kept for backward compatibility
  -- New code should use project-state module
  return vim.fn.stdpath 'data' .. '/nvim-claude'
end

-- Get project-specific state file location (DEPRECATED - kept for compatibility)
function M.get_state_file()
  -- This function is deprecated but kept for backward compatibility
  return vim.fn.stdpath 'data' .. '/nvim-claude/inline-diff-state.json'
end

-- Save current diff state
function M.save_state(diff_data)
  -- Structure:
  -- {
  --   version: 1,
  --   timestamp: <unix_timestamp>,
  --   stash_ref: "<stash_sha>",
  --   claude_edited_files: { "relative/path.lua": true }
  -- }
  -- Note: No longer save hunks/content - computed fresh from git baseline

  local hooks = require 'nvim-claude.hooks'

  logger.debug('save_state', 'Called with diff_data', diff_data)

  -- Validate stash_ref before saving
  if diff_data.stash_ref and (diff_data.stash_ref:match 'fatal:' or diff_data.stash_ref:match 'error:') then
    logger.error('save_state', 'Refusing to save corrupted baseline ref', {
      stash_ref = diff_data.stash_ref,
    })
    vim.notify('Refusing to save corrupted baseline ref: ' .. diff_data.stash_ref:sub(1, 50), vim.log.levels.ERROR)
    return
  end

  -- Check for missing stash_ref when there are tracked files
  local edited_files = diff_data.claude_edited_files or hooks.claude_edited_files or {}
  if next(edited_files) and not diff_data.stash_ref then
    logger.error('save_state', 'WARNING: Saving state with tracked files but no stash_ref!', {
      claude_edited_files = vim.tbl_keys(edited_files),
    })
  end

  local state = {
    version = 1,
    timestamp = os.time(),
    stash_ref = diff_data.stash_ref,
    claude_edited_files = edited_files,
  }

  -- Note: We no longer persist hunks/content - diffs are computed fresh from git baseline

  -- Get project root for global storage
  local project_root = utils.get_project_root()
  if not project_root then
    logger.error('save_state', 'No project root found')
    return false
  end

  -- Save using global project state
  local project_state = require 'nvim-claude.project-state'
  local success = project_state.set(project_root, 'inline_diff_state', state)
  
  if not success then
    logger.error('save_state', 'Failed to save state to global storage')
    vim.notify('Failed to save inline diff state', vim.log.levels.ERROR)
    return false
  end

  logger.info('save_state', 'Successfully saved state to global storage', {
    project = project_root,
    has_stash_ref = state.stash_ref ~= nil,
    tracked_files_count = vim.tbl_count(state.claude_edited_files),
  })

  return true
end

-- Load saved diff state
function M.load_state()
  local project_root = utils.get_project_root()
  if not project_root then
    return nil
  end

  -- Try to migrate old local state first
  local project_state = require 'nvim-claude.project-state'
  project_state.migrate_local_state(project_root)

  -- Load from global storage
  local state = project_state.get(project_root, 'inline_diff_state')
  if not state then
    return nil
  end

  -- Validate version
  if state.version ~= 1 then
    vim.notify('Incompatible inline diff state version', vim.log.levels.WARN)
    return nil
  end

  -- Check if stash still exists
  if state.stash_ref then
    -- First check if the ref looks corrupted (contains error messages)
    if state.stash_ref:match 'fatal:' or state.stash_ref:match 'error:' or not state.stash_ref:match '^[%x%s@{}%-]+$' then
      vim.notify('Detected corrupted baseline ref: ' .. state.stash_ref:sub(1, 50) .. '...', vim.log.levels.ERROR)
      vim.notify('Clearing corrupted state. Inline diffs will be reset.', vim.log.levels.WARN)
      M.clear_state()
      return nil
    end

    -- Check if it's a SHA (40 hex chars) or a stash reference
    local is_sha = state.stash_ref:match '^%x+$' and #state.stash_ref >= 7
    local check_cmd

    if is_sha then
      -- For SHA, check if the commit object exists
      check_cmd = string.format('git cat-file -e %s 2>/dev/null', state.stash_ref)
    else
      -- For stash reference, check stash list (escape special chars)
      check_cmd = string.format('git stash list | grep -q "%s"', state.stash_ref:gsub('{', '\\{'):gsub('}', '\\}'))
    end

    local result = os.execute(check_cmd)
    if result ~= 0 then
      vim.notify('Saved stash/commit no longer exists: ' .. state.stash_ref, vim.log.levels.WARN)
      M.clear_state()
      return nil
    end
  end

  return state
end

-- Create baseline using temporary index and custom refs
function M.create_baseline(message)
  local utils = require 'nvim-claude.utils'
  message = message or 'nvim-claude: baseline ' .. os.date '%Y-%m-%d %H:%M:%S'
  
  logger.info('create_baseline', 'Creating baseline with message: ' .. message)
  
  -- Get git root to run commands in the correct directory
  local git_root = utils.get_project_root()
  if not git_root then
    logger.error('create_baseline', 'No git root found')
    return nil
  end
  
  -- Find the actual .git directory (could be in a parent directory)
  local git_dir_cmd = string.format('cd "%s" && git rev-parse --git-dir', git_root)
  local git_dir, git_dir_err = utils.exec(git_dir_cmd)
  if git_dir_err or not git_dir then
    logger.error('create_baseline', 'Failed to find .git directory', { error = git_dir_err })
    return nil
  end
  git_dir = git_dir:gsub('%s+', '')
  
  -- If git_dir is relative, make it absolute
  if not git_dir:match('^/') then
    git_dir = git_root .. '/' .. git_dir
  end
  
  -- Create temporary index file with unique name
  local temp_index = string.format('%s/nvim-claude-index-%s-%s', git_dir, os.time(), vim.fn.getpid())
  
  -- Add all files to temporary index (preserves user's staging area)
  local add_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git add -A', git_root, temp_index)
  local add_result, add_err = utils.exec(add_cmd)
  
  
  if add_err then
    logger.error('create_baseline', 'Failed to add files to temp index', { error = add_err })
    os.remove(temp_index)
    return nil
  end
  
  -- Create tree object from temp index
  local tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
  local tree_sha, tree_err = utils.exec(tree_cmd)
  
  
  if tree_err or not tree_sha then
    logger.error('create_baseline', 'Failed to create tree', { error = tree_err })
    os.remove(temp_index)
    return nil
  end
  tree_sha = tree_sha:gsub('%s+', '')
  
  -- Create commit object
  local commit_cmd = string.format('cd "%s" && git commit-tree %s -m "%s"', git_root, tree_sha, message)
  local commit_sha, commit_err = utils.exec(commit_cmd)
  
  
  if commit_err or not commit_sha then
    logger.error('create_baseline', 'Failed to create commit', { error = commit_err })
    os.remove(temp_index)
    return nil
  end
  commit_sha = commit_sha:gsub('%s+', '')
  
  -- Store in custom ref
  local ref_cmd = string.format('cd "%s" && git update-ref refs/nvim-claude/baseline %s', git_root, commit_sha)
  local _, ref_err = utils.exec(ref_cmd)
  
  
  if ref_err then
    logger.error('create_baseline', 'Failed to update ref', { error = ref_err })
    -- Continue anyway - we still have the commit SHA
  end
  
  -- Clean up temp index
  os.remove(temp_index)
  
  logger.info('create_baseline', 'Successfully created baseline', {
    commit_sha = commit_sha,
    tree_sha = tree_sha,
    ref = 'refs/nvim-claude/baseline',
  })
  
  return commit_sha
end

-- Clear saved state
function M.clear_state()
  local project_root = utils.get_project_root()
  if not project_root then
    return
  end
  
  -- Clear from global storage
  local project_state = require 'nvim-claude.project-state'
  project_state.set(project_root, 'inline_diff_state', nil)
  
  -- Also clear the git ref
  M.clear_baseline_ref()
end

-- Restore diffs from saved state
function M.restore_diffs()
  logger.info('restore_diffs', 'Attempting to restore diffs from saved state')

  local state = M.load_state()
  if not state then
    logger.debug('restore_diffs', 'No saved state found')
    return false
  end

  local inline_diff = require 'nvim-claude.inline-diff'
  local restored_count = 0

  -- Note: Diff restoration now handled by hooks.lua via git baseline comparison
  -- No need to restore saved hunks - they're computed fresh when files are opened

  -- Store the stash reference for future operations
  if state.stash_ref then
    M.current_stash_ref = state.stash_ref
    logger.info('restore_diffs', 'Restored stash reference', { stash_ref = state.stash_ref })
  else
    logger.warn('restore_diffs', 'No stash reference in saved state')
  end

  -- Stash reference restored silently

  -- Restore Claude edited files tracking
  if state.claude_edited_files then
    local hooks = require 'nvim-claude.hooks'
    hooks.claude_edited_files = state.claude_edited_files
    logger.info('restore_diffs', 'Restored tracked files', {
      count = vim.tbl_count(state.claude_edited_files),
      files = vim.tbl_keys(state.claude_edited_files),
    })
  end

  return true
end

-- Note: Pending restore logic removed - diffs now computed fresh from git baseline

-- Create a stash of current changes (instead of baseline commit)
function M.create_stash(message)
  local utils = require 'nvim-claude.utils'
  message = message or 'nvim-claude: pre-edit state'

  logger.info('create_stash', 'Creating stash with message: ' .. message)

  -- Get git root to run commands in the correct directory
  local git_root = utils.get_project_root()
  if not git_root then
    logger.error('create_stash', 'No git root found')
    return nil
  end

  -- First, check git status to see if there are any changes to stash
  local status_cmd = string.format('cd "%s" && git status --porcelain', git_root)
  local status_result, status_err = utils.exec(status_cmd)

  logger.debug('create_stash', 'Git status check', {
    status_result = status_result,
    status_error = status_err,
    has_changes = status_result and status_result ~= '',
    cwd = vim.fn.getcwd(),
  })

  if status_err then
    logger.error('create_stash', 'Failed to check git status', { error = status_err })
    return nil
  end

  -- When working directory is clean, we should use HEAD as the baseline
  if not status_result or status_result:gsub('%s+', '') == '' then
    logger.info('create_stash', 'Working directory is clean, using HEAD as baseline')
    -- Get HEAD commit SHA
    local head_cmd = string.format('cd "%s" && git rev-parse HEAD', git_root)
    local head_sha, head_err = utils.exec(head_cmd)
    if not head_err and head_sha then
      head_sha = head_sha:gsub('%s+', '')
      logger.info('create_stash', 'Using HEAD commit as baseline', { sha = head_sha })
      return head_sha
    else
      logger.error('create_stash', 'Failed to get HEAD commit', { error = head_err })
      return nil
    end
  end

  -- Create a stash object without removing changes from working directory
  -- Include untracked files with --include-untracked
  local stash_cmd = string.format('cd "%s" && git stash create --include-untracked', git_root)
  local stash_hash = nil
  local err = nil
  local max_retries = 3

  -- Retry logic for flaky stash creation
  for attempt = 1, max_retries do
    stash_hash, err = utils.exec(stash_cmd)

    logger.debug('create_stash', 'Stash create attempt', {
      attempt = attempt,
      command = stash_cmd,
      raw_output = stash_hash,
      error = err,
      output_length = stash_hash and #stash_hash or 0,
      output_trimmed = stash_hash and stash_hash:gsub('%s+', '') or '',
      cwd = vim.fn.getcwd(),
    })

    -- Check if we got a valid SHA-like output
    if stash_hash and not err then
      local trimmed = stash_hash:gsub('%s+', '')
      if trimmed ~= '' and trimmed:match '^[a-f0-9]+$' and #trimmed >= 7 then
        -- Success! Break out of retry loop
        break
      end
    end

    -- If not the last attempt, wait a bit before retrying
    if attempt < max_retries then
      logger.warn('create_stash', 'Stash creation returned invalid output, retrying', {
        attempt = attempt,
        output = stash_hash,
        error = err,
      })
      vim.wait(100 * attempt) -- Progressive backoff: 100ms, 200ms, 300ms
    end
  end

  if err then
    logger.error('create_stash', 'Command execution failed after retries', {
      command = stash_cmd,
      error = err,
      output = stash_hash,
      attempts = max_retries,
    })
    return nil
  end

  if not stash_hash then
    logger.error('create_stash', 'No output from git stash create command')
    return nil
  end

  -- Trim whitespace from the result
  stash_hash = stash_hash:gsub('%s+', '')

  if stash_hash == '' then
    logger.error('create_stash', 'Empty output from git stash create - this should not happen with changes present')
    return nil
  end

  -- Check if result contains error message
  if stash_hash:match 'fatal:' or stash_hash:match 'error:' or stash_hash:match 'warning:' then
    logger.error('create_stash', 'Git returned error/warning message instead of hash', {
      result = stash_hash,
      command = stash_cmd,
    })
    return nil
  end

  -- Validate that the result looks like a git SHA
  if not stash_hash:match '^[a-f0-9]+$' or #stash_hash < 7 then
    logger.error('create_stash', 'Output does not look like a valid git SHA', {
      result = stash_hash,
      length = #stash_hash,
      hex_pattern_match = stash_hash:match '^[a-f0-9]+$' ~= nil,
    })
    return nil
  end

  logger.info('create_stash', 'Valid stash SHA created', { stash_hash = stash_hash })

  -- Store the stash with a message
  local store_cmd = string.format('cd "%s" && git stash store -m "%s" %s', git_root, message, stash_hash)
  local store_result, store_err = utils.exec(store_cmd)

  logger.debug('create_stash', 'Stash store command output', {
    command = store_cmd,
    store_result = store_result,
    store_error = store_err,
  })

  if store_err then
    logger.error('create_stash', 'Failed to store stash', {
      command = store_cmd,
      error = store_err,
      output = store_result,
    })
    return nil
  end

  -- Verify the stash was actually stored
  local verify_cmd = string.format('cd "%s" && git stash list --grep="%s"', git_root, message)
  local verify_result, verify_err = utils.exec(verify_cmd)

  logger.debug('create_stash', 'Stash verification', {
    command = verify_cmd,
    verify_result = verify_result,
    verify_error = verify_err,
    found_stash = verify_result and verify_result ~= '',
  })

  if verify_err or not verify_result or verify_result:gsub('%s+', '') == '' then
    logger.warn('create_stash', 'Stash may not have been stored properly', {
      verify_error = verify_err,
      verify_result = verify_result,
    })
  end

  logger.info('create_stash', 'Successfully created and stored stash', {
    stash_hash = stash_hash,
    message = message,
  })

  -- Return the SHA directly - it's more stable than stash@{0}
  return stash_hash
end

-- Setup autocmds for persistence
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup('NvimClaudeInlineDiffPersistence', { clear = true })

  -- Save state before exiting vim
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      local inline_diff = require 'nvim-claude.inline-diff'
      -- Only save if there are active diffs
      local has_active_diffs = false
      for _, diff in pairs(inline_diff.active_diffs) do
        if diff then
          has_active_diffs = true
          break
        end
      end

      if has_active_diffs and M.current_stash_ref then
        M.save_state { stash_ref = M.current_stash_ref }
      else
        -- Save just the Claude edited files tracking even if no active diffs
        local hooks = require 'nvim-claude.hooks'
        if hooks.claude_edited_files and next(hooks.claude_edited_files) then
          M.save_state { stash_ref = M.current_stash_ref or '' }
        end
      end
    end,
  })

  -- Note: BufReadPost autocmd removed - diff restoration handled by hooks.lua

  -- Auto-restore on VimEnter
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    once = true,
    callback = function()
      -- Delay slightly to ensure everything is loaded
      vim.defer_fn(function()
        -- Try migration first
        M.migrate_global_state()
        M.restore_diffs()
      end, 100)
    end,
  })
end

-- Migrate from global to project-specific state
function M.migrate_global_state()
  local global_state_file = vim.fn.stdpath 'data' .. '/nvim-claude-inline-diff-state.json'

  -- Check if global state exists
  if not utils.file_exists(global_state_file) then
    return
  end

  -- Check if we're in a git repo
  local project_root = utils.get_project_root()
  if not project_root or not utils.is_git_repo() then
    return
  end

  -- Check if project-specific state already exists
  local project_state_file = M.get_state_file()
  if utils.file_exists(project_state_file) then
    -- Project state exists, remove global state
    os.remove(global_state_file)
    return
  end

  -- Load global state
  local state, err = utils.read_json(global_state_file)
  if not state then
    return
  end

  -- Check if the stash belongs to this project
  if state.stash_ref then
    local check_cmd = string.format('git cat-file -e %s 2>/dev/null', state.stash_ref)
    local result = os.execute(check_cmd)
    if result == 0 then
      -- Stash exists in this repo, migrate the state
      local success = utils.write_json(project_state_file, state)
      if success then
        vim.notify('Migrated nvim-claude state to project-specific location', vim.log.levels.INFO)
      end
    end
  end

  -- Remove global state file
  os.remove(global_state_file)
end

return M
