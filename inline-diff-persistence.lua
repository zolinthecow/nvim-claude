-- Persistence layer for inline diffs
-- Manages saving/loading diff state across neovim sessions without polluting git history

local M = {}
local utils = require('nvim-claude.utils')

-- Get project-specific nvim-claude directory
function M.get_nvim_claude_dir()
  local project_root = utils.get_project_root()
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
  --   files: {
  --     "/path/to/file": {
  --       hunks: [...],
  --       applied_hunks: {...}
  --     }
  --   }
  -- }
  
  local hooks = require('nvim-claude.hooks')
  local inline_diff = require('nvim-claude.inline-diff')
  
  local state = {
    version = 1,
    timestamp = os.time(),
    stash_ref = diff_data.stash_ref,
    claude_edited_files = diff_data.claude_edited_files or hooks.claude_edited_files or {},
    diff_files = {},  -- Add diff_files to persistence
    files = {}
  }
  
  -- Save all diff files (both opened and unopened)
  for file_path, bufnr in pairs(inline_diff.diff_files) do
    state.diff_files[file_path] = bufnr
  end
  
  -- Collect state from all buffers with active diffs
  for file_path, bufnr in pairs(inline_diff.diff_files) do
    if inline_diff.active_diffs[bufnr] then
      local diff = inline_diff.active_diffs[bufnr]
      state.files[file_path] = {
        hunks = diff.hunks,
        applied_hunks = diff.applied_hunks or {},
        new_content = diff.new_content
      }
    end
  end
  
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
  
  -- Restore diffs for each file
  for file_path, file_state in pairs(state.files) do
    -- Check if file exists and hasn't changed since the diff was created
    if utils.file_exists(file_path) then
      -- Read current content
      local current_content = utils.read_file(file_path)
      
      -- Check if the file matches what we expect (either original or with applied changes)
      -- This handles the case where some hunks were accepted
      if current_content then
        -- Find or create buffer for this file
        local bufnr = vim.fn.bufnr(file_path)
        if bufnr == -1 then
          -- File not loaded, we'll restore when it's opened
          -- Store in a pending restores table
          M.pending_restores = M.pending_restores or {}
          M.pending_restores[file_path] = file_state
        else
          -- Restore the diff visualization
          -- No longer restoring original_content - we read from git stash
          inline_diff.diff_files[file_path] = bufnr
          inline_diff.active_diffs[bufnr] = {
            hunks = file_state.hunks,
            new_content = file_state.new_content,
            current_hunk = 1,
            applied_hunks = file_state.applied_hunks or {}
          }
          
          -- Apply visualization
          inline_diff.apply_diff_visualization(bufnr)
          inline_diff.setup_inline_keymaps(bufnr)
          
          restored_count = restored_count + 1
        end
      end
    end
  end
  
  if restored_count > 0 then
    -- Silent restore - no notification
  end
  
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

-- Check for pending restores when a buffer is loaded
function M.check_pending_restore(bufnr)
  if not M.pending_restores then
    return
  end
  
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local file_state = M.pending_restores[file_path]
  
  if file_state then
    local inline_diff = require('nvim-claude.inline-diff')
    
    -- Restore the diff for this buffer
    -- No longer restoring original_content - we read from git stash
    inline_diff.diff_files[file_path] = bufnr
    inline_diff.active_diffs[bufnr] = {
      hunks = file_state.hunks,
      new_content = file_state.new_content,
      current_hunk = 1,
      applied_hunks = file_state.applied_hunks or {}
    }
    
    -- Apply visualization
    inline_diff.apply_diff_visualization(bufnr)
    inline_diff.setup_inline_keymaps(bufnr)
    
    -- Remove from pending
    M.pending_restores[file_path] = nil
    
    -- Silent restore - no notification
  end
end

-- Create a stash of current changes (instead of baseline commit)
function M.create_stash(message)
  local utils = require('nvim-claude.utils')
  message = message or 'nvim-claude: pre-edit state'
  
  -- Create a stash object without removing changes from working directory
  local stash_cmd = 'git stash create'
  local stash_hash, err = utils.exec(stash_cmd)
  
  -- Debug: Log the result
  local debug_file = io.open('/tmp/nvim-claude-stash-debug.log', 'a')
  if debug_file then
    debug_file:write(string.format('[%s] create_stash called\n', os.date('%Y-%m-%d %H:%M:%S')))
    debug_file:write(string.format('  Command: %s\n', stash_cmd))
    debug_file:write(string.format('  Result: %s\n', stash_hash or 'nil'))
    debug_file:write(string.format('  Error: %s\n', err or 'nil'))
    debug_file:close()
  end
  
  if not err and stash_hash and stash_hash ~= '' then
    -- Store the stash with a message
    stash_hash = stash_hash:gsub('%s+', '') -- trim whitespace
    local store_cmd = string.format('git stash store -m "%s" %s', message, stash_hash)
    local store_result, store_err = utils.exec(store_cmd)
    
    -- Debug: Log store result
    debug_file = io.open('/tmp/nvim-claude-stash-debug.log', 'a')
    if debug_file then
      debug_file:write(string.format('  Store command: %s\n', store_cmd))
      debug_file:write(string.format('  Store result: %s\n', store_result or 'nil'))
      debug_file:write(string.format('  Store error: %s\n', store_err or 'nil'))
      debug_file:close()
    end
    
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
  
  -- Check for pending restores when buffers are loaded
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(ev)
      M.check_pending_restore(ev.buf)
    end
  })
  
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