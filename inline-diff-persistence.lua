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

-- Get project-specific nvim-claude directory
function M.get_nvim_claude_dir(file_path)
  local project_root
  if file_path then
    project_root = utils.get_project_root_for_file(file_path)
  else
    project_root = utils.get_project_root()
  end

  if not project_root then
    -- Fallback to global data directory if no project root
    return vim.fn.stdpath 'data' .. '/nvim-claude'
  end
  return project_root .. '/.nvim-claude'
end

-- Get project-specific state file location
function M.get_state_file()
  local nvim_claude_dir = M.get_nvim_claude_dir()
  utils.ensure_dir(nvim_claude_dir)
  return nvim_claude_dir .. '/inline-diff-state.json'
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

  -- Save to file
  local state_file = M.get_state_file()
  local success, err = utils.write_json(state_file, state)
  if not success then
    logger.error('save_state', 'Failed to save state file', {
      file = state_file,
      error = err,
    })
    vim.notify('Failed to save inline diff state: ' .. err, vim.log.levels.ERROR)
    return false
  end

  logger.info('save_state', 'Successfully saved state', {
    file = state_file,
    has_stash_ref = state.stash_ref ~= nil,
    tracked_files_count = vim.tbl_count(state.claude_edited_files),
  })

  return true
end

-- Load saved diff state
function M.load_state()
  local state_file = M.get_state_file()
  if not utils.file_exists(state_file) then
    return nil
  end

  local state, err = utils.read_json(state_file)
  if not state then
    vim.notify('Failed to load inline diff state: ' .. err, vim.log.levels.ERROR)
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

-- Clear saved state
function M.clear_state()
  local state_file = M.get_state_file()
  if utils.file_exists(state_file) then
    os.remove(state_file)
  end
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

  -- First, check git status to see if there are any changes to stash
  local status_cmd = 'git status --porcelain'
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

  if not status_result or status_result:gsub('%s+', '') == '' then
    logger.warn('create_stash', 'No changes to stash - working directory is clean')
    return nil
  end

  -- Create a stash object without removing changes from working directory
  local stash_cmd = 'git stash create'
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
  local store_cmd = string.format('git stash store -m "%s" %s', message, stash_hash)
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
  local verify_cmd = string.format('git stash list --grep="%s"', message)
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

