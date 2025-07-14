-- Claude Code hooks integration for nvim-claude
local M = {}

-- Track hook state
M.pre_edit_commit = nil
M.stable_baseline_ref = nil -- The stable baseline to compare all changes against
M.claude_edited_files = {} -- Track which files Claude has edited

-- Update stable baseline after accepting changes
function M.update_stable_baseline()
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Create a new stash with current state as the new baseline
  local message = 'nvim-claude-baseline-accepted-' .. os.time()

  -- Create a stash object without removing changes from working directory
  local stash_cmd = 'git stash create'
  local stash_hash, err = utils.exec(stash_cmd)

  if not err and stash_hash and stash_hash ~= '' then
    -- Store the stash with a message
    stash_hash = stash_hash:gsub('%s+', '') -- trim whitespace
    local store_cmd = string.format('git stash store -m "%s" %s', message, stash_hash)
    utils.exec(store_cmd)

    -- Update our stable baseline reference
    M.stable_baseline_ref = stash_hash
    persistence.current_stash_ref = stash_hash

    -- Save the updated state
    persistence.save_state { stash_ref = stash_hash }
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
  vim.notify(string.format('PRE-HOOK CALLED! Count: %d, Time: %s', _G.NVIM_CLAUDE_PRE_HOOK_COUNT, os.date '%H:%M:%S'), vim.log.levels.WARN)

  -- For now, just return true without doing anything else
  return true
end

-- Per-file baseline management pre-hook
function M.pre_tool_use_hook(file_path)
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Debug: Log to file with error handling
  local ok, err = pcall(function()
    local debug_file = io.open('/tmp/nvim-claude-hook-debug.log', 'a')
    if debug_file then
      debug_file:write(string.format('\n[%s] PRE_HOOK START (file_path: %s)\n', os.date('%Y-%m-%d %H:%M:%S.%f'):sub(1, -4), file_path or 'nil'))
      M._debug_file = debug_file
    end
  end)

  if not ok then
    local f = io.open('/tmp/nvim-claude-hook-debug.log', 'a')
    if f then
      f:write(string.format('\n[%s] PRE_HOOK ERROR: %s\n', os.date '%Y-%m-%d %H:%M:%S', tostring(err)))
      f:close()
    end
  end

  local debug_file = M._debug_file

  -- If no file path provided, fall back to old behavior
  if not file_path then
    if debug_file then
      debug_file:write('  No file path provided, using legacy behavior\n')
    end
    return M.legacy_pre_tool_use_hook()
  end

  local git_root = utils.get_project_root()
  if not git_root then
    if debug_file then
      debug_file:write('  Not in git repository\n')
      debug_file:close()
    end
    return true
  end

  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  if debug_file then
    debug_file:write(string.format('  Git root: %s\n', git_root))
    debug_file:write(string.format('  Relative path: %s\n', relative_path))
    debug_file:write(string.format('  Current baseline ref: %s\n', M.stable_baseline_ref or 'nil'))
    debug_file:write(string.format('  File already tracked: %s\n', tostring(M.claude_edited_files[relative_path] ~= nil)))
  end

  -- Case 1: No baseline exists at all → create full baseline stash
  if not M.stable_baseline_ref then
    if debug_file then
      debug_file:write('  Creating initial baseline stash\n')
    end
    
    local stash_ref = persistence.create_stash('nvim-claude: baseline ' .. os.date '%Y-%m-%d %H:%M:%S')
    if stash_ref then
      M.stable_baseline_ref = stash_ref
      persistence.current_stash_ref = stash_ref
      
      if debug_file then
        debug_file:write(string.format('  Created baseline stash: %s\n', stash_ref))
      end
    else
      if debug_file then
        debug_file:write('  ERROR: Failed to create baseline stash\n')
      end
    end
  
  -- Case 2: File already Claude-edited → do nothing (baseline already captured)
  elseif M.claude_edited_files[relative_path] then
    if debug_file then
      debug_file:write('  File already tracked, no baseline update needed\n')
    end
  
  -- Case 3: New file for Claude to edit → update baseline for this specific file
  else
    -- Check if file exists before updating baseline
    local full_path = git_root .. '/' .. relative_path
    if utils.file_exists(full_path) then
      if debug_file then
        debug_file:write('  New file to edit, updating baseline\n')
      end
      
      M.update_baseline_for_file(relative_path, git_root)
    else
      if debug_file then
        debug_file:write('  File does not exist, skipping baseline update (will be treated as new file)\n')
      end
    end
  end

  if debug_file then
    debug_file:write(string.format('[%s] PRE_HOOK END\n', os.date '%Y-%m-%d %H:%M:%S'))
    debug_file:close()
  end

  return true
end

-- Legacy pre-hook for backward compatibility
function M.legacy_pre_tool_use_hook()
  local persistence = require 'nvim-claude.inline-diff-persistence'

  -- Only create a baseline if we don't have one yet
  if not M.stable_baseline_ref then
    local stash_ref = persistence.create_stash('nvim-claude: baseline ' .. os.date '%Y-%m-%d %H:%M:%S')
    if stash_ref then
      M.stable_baseline_ref = stash_ref
      persistence.current_stash_ref = stash_ref
    end
  end

  return true
end

-- Update baseline stash to include current state of a specific file
function M.update_baseline_for_file(relative_path, git_root)
  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'
  
  local debug_file = M._debug_file
  
  if debug_file then
    debug_file:write(string.format('  Updating baseline for file: %s\n', relative_path))
  end
  
  -- Check if file exists on disk
  local full_path = git_root .. '/' .. relative_path
  if not utils.file_exists(full_path) then
    if debug_file then
      debug_file:write('  File does not exist on disk, skipping baseline update\n')
    end
    return
  end
  
  -- Strategy: Create a new stash that combines the existing baseline with current file state
  -- 1. Create a temporary commit with current file state
  -- 2. Use git cherry-pick or patch to apply current file to baseline
  -- 3. Create new stash from result
  
  -- Read current file content
  local current_content = utils.read_file(full_path)
  if not current_content then
    if debug_file then
      debug_file:write('  Could not read current file content\n')
    end
    return
  end
  
  -- Create a temporary file with current content
  local temp_file = '/tmp/nvim-claude-baseline-update-' .. os.time()
  utils.write_file(temp_file, current_content)
  
  -- Use git's plumbing to create a new tree that combines baseline + current file
  local success = pcall(function()
    -- Get the tree of the current baseline stash
    local baseline_tree_cmd = string.format('cd "%s" && git rev-parse %s^{tree}', git_root, M.stable_baseline_ref)
    local baseline_tree, err = utils.exec(baseline_tree_cmd)
    
    if err or not baseline_tree then
      error('Failed to get baseline tree: ' .. (err or 'unknown error'))
    end
    
    baseline_tree = baseline_tree:gsub('%s+', '') -- trim whitespace
    
    if debug_file then
      debug_file:write(string.format('  Baseline tree: %s\n', baseline_tree))
    end
    
    -- Create a blob for the current file content
    local blob_cmd = string.format('cd "%s" && git hash-object -w "%s"', git_root, temp_file)
    local blob_hash, blob_err = utils.exec(blob_cmd)
    
    if blob_err or not blob_hash then
      error('Failed to create blob: ' .. (blob_err or 'unknown error'))
    end
    
    blob_hash = blob_hash:gsub('%s+', '') -- trim whitespace
    
    if debug_file then
      debug_file:write(string.format('  Created blob: %s\n', blob_hash))
    end
    
    -- Read the baseline tree and update it with the new file
    local tree_cmd = string.format('cd "%s" && git ls-tree %s', git_root, baseline_tree)
    local tree_content, tree_err = utils.exec(tree_cmd)
    
    if tree_err then
      error('Failed to read tree: ' .. tree_err)
    end
    
    -- Parse tree content and update/add our file
    local new_tree_entries = {}
    local file_found = false
    
    if tree_content and tree_content ~= '' then
      for line in tree_content:gmatch('[^\n]+') do
        local mode, type, hash, name = line:match('^(%d+) (%w+) (%x+)\t(.+)$')
        if mode and type and hash and name then
          if name == relative_path then
            -- Update existing file
            table.insert(new_tree_entries, string.format('%s %s %s\t%s', mode, type, blob_hash, name))
            file_found = true
          else
            -- Keep existing entry
            table.insert(new_tree_entries, line)
          end
        end
      end
    end
    
    -- Add file if it wasn't found in the tree
    if not file_found then
      table.insert(new_tree_entries, string.format('100644 blob %s\t%s', blob_hash, relative_path))
    end
    
    -- Create new tree
    local new_tree_input = table.concat(new_tree_entries, '\n')
    if new_tree_input ~= '' then
      new_tree_input = new_tree_input .. '\n'
    end
    
    -- Write tree input to temp file
    local tree_input_file = '/tmp/nvim-claude-tree-input-' .. os.time()
    utils.write_file(tree_input_file, new_tree_input)
    
    local new_tree_cmd = string.format('cd "%s" && git mktree < "%s"', git_root, tree_input_file)
    local new_tree_hash, new_tree_err = utils.exec(new_tree_cmd)
    
    -- Clean up temp files
    os.remove(tree_input_file)
    
    if new_tree_err or not new_tree_hash then
      error('Failed to create new tree: ' .. (new_tree_err or 'unknown error'))
    end
    
    new_tree_hash = new_tree_hash:gsub('%s+', '') -- trim whitespace
    
    if debug_file then
      debug_file:write(string.format('  Created new tree: %s\n', new_tree_hash))
    end
    
    -- Create a commit from the new tree
    local commit_message = string.format('nvim-claude: updated baseline for %s at %s', relative_path, os.date '%Y-%m-%d %H:%M:%S')
    local commit_cmd = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', git_root, new_tree_hash, M.stable_baseline_ref, commit_message)
    local new_commit_hash, commit_err = utils.exec(commit_cmd)
    
    if commit_err or not new_commit_hash then
      error('Failed to create commit: ' .. (commit_err or 'unknown error'))
    end
    
    new_commit_hash = new_commit_hash:gsub('%s+', '') -- trim whitespace
    
    if debug_file then
      debug_file:write(string.format('  Created new commit: %s\n', new_commit_hash))
    end
    
    -- Update our baseline reference to the new commit
    M.stable_baseline_ref = new_commit_hash
    persistence.current_stash_ref = new_commit_hash
    
    -- Save persistence state
    persistence.save_state({
      stash_ref = new_commit_hash,
      claude_edited_files = M.claude_edited_files
    })
    
    if debug_file then
      debug_file:write(string.format('  Updated baseline ref to: %s\n', new_commit_hash))
    end
  end)
  
  -- Clean up temp file
  os.remove(temp_file)
  
  if not success then
    if debug_file then
      debug_file:write('  ERROR: Failed to update baseline\n')
    end
  end
end

-- Post-tool-use hook: Track Claude-edited file and refresh if currently open
function M.post_tool_use_hook(file_path)
  if not file_path then 
    return 
  end

  local utils = require 'nvim-claude.utils'
  local persistence = require 'nvim-claude.inline-diff-persistence'
  local git_root = utils.get_project_root()
  
  if not git_root then
    return
  end

  -- Track this file as Claude-edited
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  M.claude_edited_files[relative_path] = true

  -- Also add to diff_files for <leader>ci to show it immediately
  local inline_diff = require 'nvim-claude.inline-diff'
  inline_diff.diff_files[file_path] = -1  -- -1 indicates unopened file

  -- Save to persistence
  persistence.save_state({ 
    stash_ref = M.stable_baseline_ref,
    claude_edited_files = M.claude_edited_files 
  })

  -- If this file is currently open in a buffer, refresh it and show diff
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == file_path then
        -- Refresh the buffer to show Claude's changes
        vim.api.nvim_buf_call(buf, function()
          vim.cmd('checktime')
        end)
        
        -- Show inline diff if we have a baseline
        if M.stable_baseline_ref then
          M.show_inline_diff_for_file(buf, relative_path, git_root, M.stable_baseline_ref)
        end
        break
      end
    end
  end
end

-- Helper function to show inline diff for a file
function M.show_inline_diff_for_file(buf, file, git_root, stash_ref)
  local utils = require 'nvim-claude.utils'
  local inline_diff = require 'nvim-claude.inline-diff'

  -- Only show inline diff if Claude edited this file
  if not M.claude_edited_files[file] then
    return false
  end

  -- Get baseline from git stash
  local stash_cmd = string.format('cd "%s" && git show %s:%s 2>/dev/null', git_root, stash_ref, file)
  local original_content, git_err = utils.exec(stash_cmd)

  -- If file doesn't exist in baseline, treat as new file (empty baseline)
  if git_err or not original_content then
    original_content = ''
  end

  -- Get current content
  local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')

  -- Show inline diff (empty baseline will show entire file as additions)
  inline_diff.show_inline_diff(buf, original_content, current_content)
  return true
end

-- -- Test inline diff manually
-- function M.test_inline_diff()
--   vim.notify('Testing inline diff manually...', vim.log.levels.INFO)
--
--   local utils = require 'nvim-claude.utils'
--   local persistence = require 'nvim-claude.inline-diff-persistence'
--   local git_root = utils.get_project_root()
--
--   if not git_root then
--     vim.notify('Not in git repository', vim.log.levels.ERROR)
--     return
--   end
--
--   -- Get current buffer
--   local bufnr = vim.api.nvim_get_current_buf()
--   local buf_name = vim.api.nvim_buf_get_name(bufnr)
--
--   if buf_name == '' then
--     vim.notify('Current buffer has no file', vim.log.levels.ERROR)
--     return
--   end
--
--   -- Get relative path
--   local relative_path = buf_name:gsub(git_root .. '/', '')
--   vim.notify('Testing inline diff for: ' .. relative_path, vim.log.levels.INFO)
--
--   -- Get baseline content - check for updated baseline first
--   local inline_diff = require 'nvim-claude.inline-diff'
--   local original_content = nil
--
--   -- Check if we have an updated baseline in memory
--
--   if inline_diff.original_content[bufnr] then
--     original_content = inline_diff.original_content[bufnr]
--     vim.notify('Using updated baseline from memory (length: ' .. #original_content .. ')', vim.log.levels.INFO)
--   elseif persistence.current_stash_ref then
--     -- Try to get from stash
--     local stash_cmd = string.format('cd "%s" && git show %s:%s 2>/dev/null', git_root, persistence.current_stash_ref, relative_path)
--     local git_err
--     original_content, git_err = utils.exec(stash_cmd)
--
--     if git_err then
--       vim.notify('Failed to get stash content: ' .. git_err, vim.log.levels.ERROR)
--       return
--     end
--     vim.notify('Using stash baseline: ' .. persistence.current_stash_ref, vim.log.levels.INFO)
--   else
--     -- Fall back to HEAD
--     local baseline_cmd = string.format('cd "%s" && git show HEAD:%s 2>/dev/null', git_root, relative_path)
--     local git_err
--     original_content, git_err = utils.exec(baseline_cmd)
--
--     if git_err then
--       vim.notify('Failed to get baseline content: ' .. git_err, vim.log.levels.ERROR)
--       return
--     end
--     vim.notify('Using HEAD as baseline', vim.log.levels.INFO)
--   end
--
--   -- Get current content
--   local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
--   local current_content = table.concat(current_lines, '\n')
--
--   -- Show inline diff
--   inline_diff.show_inline_diff(bufnr, original_content, current_content)
-- end

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

      -- Check if this file was edited by Claude
      if M.claude_edited_files[relative_path] and M.stable_baseline_ref then
        -- Show inline diff for this file
        vim.defer_fn(function()
          M.show_inline_diff_for_file(bufnr, relative_path, git_root, M.stable_baseline_ref)
        end, 50) -- Small delay to ensure buffer is fully loaded
      else
        -- Check if persistence has pending restores for this file
        local persistence = require 'nvim-claude.inline-diff-persistence'
        if persistence.pending_restores and persistence.pending_restores[file_path] then
          -- Persistence system will handle this
          persistence.check_pending_restore(bufnr)
        elseif persistence.current_stash_ref then
          -- Check if we have persistence state but haven't restored claude_edited_files yet
          local state = persistence.load_state()
          if state and state.claude_edited_files and state.claude_edited_files[relative_path] then
            -- File is tracked in persistence, show diff
            M.stable_baseline_ref = M.stable_baseline_ref or state.stash_ref
            M.claude_edited_files[relative_path] = true
            vim.defer_fn(function()
              M.show_inline_diff_for_file(bufnr, relative_path, git_root, M.stable_baseline_ref)
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

  -- Setup persistence autocmds
  persistence.setup_autocmds()

  -- Try to restore any saved diffs
  local restored = persistence.restore_diffs()

  -- Also restore the baseline reference from persistence if it exists
  if persistence.current_stash_ref then
    M.stable_baseline_ref = persistence.current_stash_ref
  end

  -- Don't create a startup baseline - only create baselines when Claude makes edits
end

-- -- Manual hook testing
-- function M.test_hooks()
--   vim.notify('=== Testing nvim-claude hooks ===', vim.log.levels.INFO)
--
--   local persistence = require 'nvim-claude.inline-diff-persistence'
--
--   -- Test creating a stash
--   vim.notify('1. Creating test stash...', vim.log.levels.INFO)
--   local stash_ref = persistence.create_stash('nvim-claude: test stash')
--
--   if stash_ref then
--     persistence.current_stash_ref = stash_ref
--     vim.notify('Stash created: ' .. stash_ref, vim.log.levels.INFO)
--   else
--     vim.notify('Failed to create stash', vim.log.levels.ERROR)
--   end
--
--   -- Simulate making a change
--   vim.notify('2. Make some changes to test files now...', vim.log.levels.INFO)
--
--   -- Test post-tool-use hook after a delay
--   vim.notify('3. Will trigger post-tool-use hook in 3 seconds...', vim.log.levels.INFO)
--
--   vim.defer_fn(function()
--     M.post_tool_use_hook()
--   end, 3000)
--
--   vim.notify('=== Hook testing started - make changes now! ===', vim.log.levels.INFO)
-- end

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
  local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
  -- Use a simpler command that doesn't require complex quoting
  local pre_command = plugin_dir .. '/pre-hook-wrapper.sh'
  local post_command = plugin_dir .. '/post-hook-wrapper.sh'

  local hooks_config = {
    hooks = {
      PreToolUse = {
        {
          matcher = 'Edit|Write|MultiEdit', -- Only match file editing tools
          hooks = {
            {
              type = 'command',
              command = pre_command,
            },
          },
        },
      },
      PostToolUse = {
        {
          matcher = 'Edit|Write|MultiEdit', -- Only match file editing tools
          hooks = {
            {
              type = 'command',
              command = post_command,
            },
          },
        },
      },
    },
  }

  -- Write hooks configuration
  local settings_file = claude_dir .. '/settings.json'
  local success, err = utils.write_json(settings_file, hooks_config)

  if success then
    -- Add .claude to gitignore if needed
    local gitignore_path = project_root .. '/.gitignore'
    local gitignore_content = utils.read_file(gitignore_path) or ''

    local entries_to_add = {}

    -- Check for .claude/
    if not gitignore_content:match '%.claude/' then
      table.insert(entries_to_add, '.claude/')
    end

    -- Check for .nvim-server
    if not gitignore_content:match '%.nvim%-server' then
      table.insert(entries_to_add, '.nvim-server')
    end

    -- Add entries if needed
    if #entries_to_add > 0 then
      local new_content = gitignore_content .. '\n# Claude Code hooks\n' .. table.concat(entries_to_add, '\n') .. '\n'
      utils.write_file(gitignore_path, new_content)
      vim.notify('Added ' .. table.concat(entries_to_add, ', ') .. ' to .gitignore', vim.log.levels.INFO)
    end
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

  local settings_file = project_root .. '/.claude/settings.json'

  if vim.fn.filereadable(settings_file) then
    vim.fn.delete(settings_file)
    vim.notify('Claude Code hooks uninstalled', vim.log.levels.INFO)
  else
    vim.notify('No hooks configuration found', vim.log.levels.INFO)
  end
end

-- Commands for manual hook management
function M.setup_commands()
  -- Test commands (commented out for release)
  -- vim.api.nvim_create_user_command('ClaudeTestHooks', function()
  --   M.test_hooks()
  -- end, {
  --   desc = 'Test Claude Code hooks',
  -- })
  --
  -- vim.api.nvim_create_user_command('ClaudeTestInlineDiff', function()
  --   M.test_inline_diff()
  -- end, {
  --   desc = 'Test Claude inline diff manually',
  -- })
  --
  -- vim.api.nvim_create_user_command('ClaudeTestKeymap', function()
  --   require('nvim-claude.inline-diff').test_keymap()
  -- end, {
  --   desc = 'Test Claude keymap functionality',
  -- })

  vim.api.nvim_create_user_command('ClaudeDebugInlineDiff', function()
    require('nvim-claude.inline-diff-debug').debug_inline_diff()
  end, {
    desc = 'Debug Claude inline diff state',
  })

  vim.api.nvim_create_user_command('ClaudeUpdateBaseline', function()
    local bufnr = vim.api.nvim_get_current_buf()
    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local current_content = table.concat(current_lines, '\n')

    local inline_diff = require 'nvim-claude.inline-diff'
    inline_diff.original_content[bufnr] = current_content

    -- Save updated state
    local persistence = require 'nvim-claude.inline-diff-persistence'
    if persistence.current_stash_ref then
      persistence.save_state { stash_ref = persistence.current_stash_ref }
    end

    vim.notify('Baseline updated to current buffer state', vim.log.levels.INFO)
  end, {
    desc = 'Update Claude baseline to current buffer state',
  })

  -- vim.api.nvim_create_user_command('ClaudeTestDiff', function()
  --   local utils = require 'nvim-claude.utils'
  --
  --   -- Check if we're in a git repository
  --   local git_root = utils.get_project_root()
  --   if not git_root then
  --     return
  --   end
  --
  --   -- Check if there are any changes
  --   local status_cmd = string.format('cd "%s" && git status --porcelain', git_root)
  --   local status_result = utils.exec(status_cmd)
  --
  --   if not status_result or status_result == '' then
  --     vim.notify('No changes to test', vim.log.levels.INFO)
  --     return
  --   end
  --
  --   -- Create test stash without restoring (to avoid conflicts)
  --   local timestamp = os.date '%Y-%m-%d %H:%M:%S'
  --   local stash_msg = string.format('[claude-test] %s', timestamp)
  --
  --   local stash_cmd = string.format('cd "%s" && git stash push -u -m "%s"', git_root, stash_msg)
  --   local stash_result, stash_err = utils.exec(stash_cmd)
  --
  --   if stash_err then
  --     vim.notify('Failed to create test stash: ' .. stash_err, vim.log.levels.ERROR)
  --     return
  --   end
  --
  --   -- Trigger diff review with the stash (no pre-edit ref for manual test)
  --   local diff_review = require 'nvim-claude.diff-review'
  --   diff_review.handle_claude_edit('stash@{0}', nil)
  --
  --   -- Pop the stash to restore changes
  --   vim.defer_fn(function()
  --     local pop_cmd = string.format('cd "%s" && git stash pop --quiet', git_root)
  --     utils.exec(pop_cmd)
  --     vim.cmd 'checktime' -- Refresh buffers
  --   end, 100)
  -- end, {
  --   desc = 'Test Claude diff review with current changes',
  -- })

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
    local inline_diff = require 'nvim-claude.inline-diff'
    local persistence = require 'nvim-claude.inline-diff-persistence'

    -- Clear in-memory baselines
    inline_diff.original_content = {}

    -- Clear stable baseline reference
    M.stable_baseline_ref = nil
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
    if not M.stable_baseline_ref then
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
            M.stable_baseline_ref = stash_sha
            persistence.current_stash_ref = stash_sha
            vim.notify('Using baseline: ' .. stash_sha .. ' (from ' .. stash_ref .. ')', vim.log.levels.INFO)
          end
        end
      end
    end
  end, {
    desc = 'Track all modified files as Claude-edited (for debugging)',
  })

  -- vim.api.nvim_create_user_command('ClaudeDebugTracking', function()
  --   -- Debug command to show current tracking state
  --   local inline_diff = require 'nvim-claude.inline-diff'
  --   local persistence = require 'nvim-claude.inline-diff-persistence'
  --   local utils = require 'nvim-claude.utils'
  --
  --   vim.notify('=== Claude Tracking Debug ===', vim.log.levels.INFO)
  --   vim.notify('Stable baseline: ' .. (M.stable_baseline_ref or 'none'), vim.log.levels.INFO)
  --   vim.notify('Persistence stash ref: ' .. (persistence.current_stash_ref or 'none'), vim.log.levels.INFO)
  --   vim.notify(string.format('Claude edited files: %d', vim.tbl_count(M.claude_edited_files)), vim.log.levels.INFO)
  --   vim.notify('Diff files: ' .. vim.inspect(vim.tbl_keys(inline_diff.diff_files)), vim.log.levels.INFO)
  --   vim.notify('Active diffs: ' .. vim.inspect(vim.tbl_keys(inline_diff.active_diffs)), vim.log.levels.INFO)
  --
  --   -- Check current file
  --   local current_file = vim.api.nvim_buf_get_name(0)
  --   local git_root = utils.get_project_root()
  --   if git_root then
  --     local relative_path = current_file:gsub('^' .. vim.pesc(git_root) .. '/', '')
  --     vim.notify('Current file relative path: ' .. relative_path, vim.log.levels.INFO)
  --     vim.notify('Is tracked: ' .. tostring(M.claude_edited_files[relative_path] ~= nil), vim.log.levels.INFO)
  --   end
  -- end, {
  --   desc = 'Debug Claude tracking state',
  -- })

  vim.api.nvim_create_user_command('ClaudeRestoreState', function()
    -- Manually restore the state
    local persistence = require 'nvim-claude.inline-diff-persistence'
    local restored = persistence.restore_diffs()

    if persistence.current_stash_ref then
      M.stable_baseline_ref = persistence.current_stash_ref
    end

    vim.notify('Manually restored state', vim.log.levels.INFO)
  end, {
    desc = 'Manually restore Claude diff state',
  })

  vim.api.nvim_create_user_command('ClaudeCleanStaleTracking', function()
    local utils = require 'nvim-claude.utils'
    local persistence = require 'nvim-claude.inline-diff-persistence'
    local git_root = utils.get_project_root()

    if not git_root or not M.stable_baseline_ref then
      vim.notify('No git root or baseline found', vim.log.levels.ERROR)
      return
    end

    local cleaned_count = 0
    local files_to_remove = {}

    -- Check each tracked file for actual differences
    for file_path, _ in pairs(M.claude_edited_files) do
      local diff_cmd = string.format('cd "%s" && git diff %s -- "%s" 2>/dev/null', git_root, M.stable_baseline_ref, file_path)
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

return M
