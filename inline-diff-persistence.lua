-- Persistence layer for inline diffs
-- Manages saving/loading diff state across neovim sessions without polluting git history
-- 
-- Clean Architecture:
-- - Only persists git stash SHA reference and tracked file list
-- - All diffs are computed fresh from git baseline vs current state
-- - No cached diff data or hunks

local M = {}
local utils = require('nvim-claude.utils')

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
    return vim.fn.stdpath('data') .. '/nvim-claude'
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
  --   claude_edited_files: { "relative/path.lua": true },
  --   diff_files: { "/full/path.lua": bufnr }
  -- }
  -- Note: No longer save hunks/content - computed fresh from git baseline
  
  local hooks = require('nvim-claude.hooks')
  local inline_diff = require('nvim-claude.inline-diff')
  
  -- Validate stash_ref before saving
  if diff_data.stash_ref and (diff_data.stash_ref:match('fatal:') or diff_data.stash_ref:match('error:')) then
    vim.notify('Refusing to save corrupted baseline ref: ' .. diff_data.stash_ref:sub(1, 50), vim.log.levels.ERROR)
    return
  end
  
  local state = {
    version = 1,
    timestamp = os.time(),
    stash_ref = diff_data.stash_ref,
    claude_edited_files = diff_data.claude_edited_files or hooks.claude_edited_files or {},
    diff_files = {},  -- Add diff_files to persistence
  }
  
  -- Save all diff files (both opened and unopened)
  for file_path, bufnr in pairs(inline_diff.diff_files) do
    state.diff_files[file_path] = bufnr
  end
  
  -- Note: We no longer persist hunks/content - diffs are computed fresh from git baseline
  
  -- Save to file
  local state_file = M.get_state_file()
  local success, err = utils.write_json(state_file, state)
  if not success then
    vim.notify('Failed to save inline diff state: ' .. err, vim.log.levels.ERROR)
    return false
  end
  
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
    if state.stash_ref:match('fatal:') or state.stash_ref:match('error:') or 
       not state.stash_ref:match('^[%x%s@{}%-]+$') then
      vim.notify('Detected corrupted baseline ref: ' .. state.stash_ref:sub(1, 50) .. '...', vim.log.levels.ERROR)
      vim.notify('Clearing corrupted state. Inline diffs will be reset.', vim.log.levels.WARN)
      M.clear_state()
      return nil
    end
    
    -- Check if it's a SHA (40 hex chars) or a stash reference
    local is_sha = state.stash_ref:match('^%x+$') and #state.stash_ref >= 7
    local check_cmd
    
    if is_sha then
      -- For SHA, check if the commit object exists
      check_cmd = string.format('git cat-file -e %s 2>/dev/null', state.stash_ref)
    else
      -- For stash reference, check stash list (escape special chars)
      check_cmd = string.format('git stash list | grep -q "%s"', state.stash_ref:gsub("{", "\\{"):gsub("}", "\\}"))
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
  local state = M.load_state()
  if not state then
    return false
  end
  
  local inline_diff = require('nvim-claude.inline-diff')
  local restored_count = 0
  
  -- Note: Diff restoration now handled by hooks.lua via git baseline comparison
  -- No need to restore saved hunks - they're computed fresh when files are opened
  
  -- Store the stash reference for future operations
  M.current_stash_ref = state.stash_ref
  
  -- Stash reference restored silently
  
  -- Restore Claude edited files tracking
  if state.claude_edited_files then
    local hooks = require('nvim-claude.hooks')
    hooks.claude_edited_files = state.claude_edited_files
  end
  
  -- Restore diff_files for unopened files
  if state.diff_files then
    for file_path, bufnr in pairs(state.diff_files) do
      -- Only restore if not already restored as an active diff
      if not inline_diff.diff_files[file_path] then
        -- Use -1 to indicate unopened file
        inline_diff.diff_files[file_path] = bufnr == -1 and -1 or -1
      end
    end
  end
  
  -- Also populate diff_files from claude_edited_files if needed
  -- This ensures <leader>ci works even if diff_files wasn't properly saved
  if state.claude_edited_files then
    local utils = require('nvim-claude.utils')
    local git_root = utils.get_project_root()
    
    if git_root then
      for relative_path, _ in pairs(state.claude_edited_files) do
        local full_path = git_root .. '/' .. relative_path
        -- Only add if not already in diff_files
        if not inline_diff.diff_files[full_path] then
          inline_diff.diff_files[full_path] = -1  -- Mark as unopened
        end
      end
    end
  end
  
  return true
end

-- Note: Pending restore logic removed - diffs now computed fresh from git baseline

-- Create a stash of current changes (instead of baseline commit)
function M.create_stash(message)
  local utils = require('nvim-claude.utils')
  message = message or 'nvim-claude: pre-edit state'
  
  -- Create a stash object without removing changes from working directory
  local stash_cmd = 'git stash create'
  local stash_hash, err = utils.exec(stash_cmd)
  
  
  if not err and stash_hash and stash_hash ~= '' then
    -- Store the stash with a message
    stash_hash = stash_hash:gsub('%s+', '') -- trim whitespace
    local store_cmd = string.format('git stash store -m "%s" %s', message, stash_hash)
    local store_result, store_err = utils.exec(store_cmd)
    
    
    -- Return the SHA directly - it's more stable than stash@{0}
    return stash_hash
  end
  
  return nil
end

-- Setup autocmds for persistence
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup('NvimClaudeInlineDiffPersistence', { clear = true })
  
  -- Save state before exiting vim
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      local inline_diff = require('nvim-claude.inline-diff')
      -- Only save if there are active diffs
      local has_active_diffs = false
      for _, diff in pairs(inline_diff.active_diffs) do
        if diff then
          has_active_diffs = true
          break
        end
      end
      
      if has_active_diffs and M.current_stash_ref then
        M.save_state({ stash_ref = M.current_stash_ref })
      else
        -- Save just the Claude edited files tracking even if no active diffs
        local hooks = require('nvim-claude.hooks')
        if hooks.claude_edited_files and next(hooks.claude_edited_files) then
          M.save_state({ stash_ref = M.current_stash_ref or '' })
        end
      end
    end
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
    end
  })
end

-- Migrate from global to project-specific state
function M.migrate_global_state()
  local global_state_file = vim.fn.stdpath('data') .. '/nvim-claude-inline-diff-state.json'
  
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