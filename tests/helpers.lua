local M = {}

-- Test utilities for inline-diff tests
local function create_temp_dir()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  return temp_dir
end

-- Initialize a git repository for testing
function M.setup_test_repo()
  M.test_dir = create_temp_dir()
  M.orig_cwd = vim.fn.getcwd()
  vim.cmd('cd ' .. M.test_dir)
  
  -- Initialize git repo
  vim.fn.system('git init')
  vim.fn.system('git config user.email "test@example.com"')
  vim.fn.system('git config user.name "Test User"')
  
  -- Clear any existing state
  local hooks = require('nvim-claude.hooks')
  hooks.stable_baseline_ref = nil
  hooks.claude_edited_files = {}
  
  -- Setup autocmd for file opening
  hooks.setup_file_open_autocmd()
  
  -- Clear persistence
  local persistence = require('nvim-claude.inline-diff-persistence')
  persistence.clear_state()
end

-- Clean up test environment
function M.cleanup()
  if M.orig_cwd then
    vim.cmd('cd ' .. M.orig_cwd)
  end
  if M.test_dir then
    vim.fn.delete(M.test_dir, 'rf')
  end
  
  -- Clear all state
  local hooks = require('nvim-claude.hooks')
  hooks.stable_baseline_ref = nil
  hooks.claude_edited_files = {}
  
  -- Clear any active diffs
  local inline_diff = require('nvim-claude.inline-diff')
  inline_diff.active_diffs = {}
end

-- Create a file with multiple hunks for testing
function M.create_file_with_hunks(num_hunks)
  local filename = 'test_file.txt'
  local content = {}
  
  -- Create original content
  for i = 1, num_hunks * 10 do
    table.insert(content, 'line ' .. i)
  end
  
  -- Write original file
  vim.fn.writefile(content, filename)
  
  -- Commit original
  vim.fn.system('git add ' .. filename)
  vim.fn.system('git commit -m "Initial commit"')
  
  -- Create baseline stash
  local hooks = require('nvim-claude.hooks')
  hooks.pre_tool_use_hook('Edit', filename)
  
  -- Modify file to create hunks
  local modified_content = vim.deepcopy(content)
  for i = 1, num_hunks do
    local line_num = i * 10 - 5
    modified_content[line_num] = 'MODIFIED line ' .. line_num
    table.insert(modified_content, line_num + 1, 'ADDED line after ' .. line_num)
  end
  
  -- Write modified content
  vim.fn.writefile(modified_content, filename)
  
  -- Track as Claude-edited with relative path
  local git_root = vim.fn.fnamemodify(M.test_dir, ':p')
  local full_path = vim.fn.fnamemodify(filename, ':p')
  local relative_path = full_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  -- Manually add to tracked files since we're not going through the full hook flow
  hooks.claude_edited_files[relative_path] = true
  
  -- Open the file to create a buffer
  vim.cmd('edit ' .. filename)
  
  return vim.fn.fnamemodify(filename, ':p')
end

-- Check if baseline contains specific content
function M.baseline_contains(file_path, content)
  local hooks = require('nvim-claude.hooks')
  local git_root = vim.fn.fnamemodify(M.test_dir, ':p')
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  if not hooks.stable_baseline_ref then
    return false
  end
  
  local cmd = string.format('git show %s:%s', hooks.stable_baseline_ref, relative_path)
  local baseline_content = vim.fn.system(cmd)
  
  return baseline_content:find(content, 1, true) ~= nil
end

-- Get current hunks for a file
function M.get_hunks(file_path)
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr == -1 then
    vim.cmd('edit ' .. file_path)
    bufnr = vim.fn.bufnr(file_path)
  end
  
  local inline_diff = require('nvim-claude.inline-diff')
  local diff_data = inline_diff.active_diffs[bufnr]
  
  return diff_data and diff_data.hunks or {}
end

-- Show diff for a file (direct approach for testing)
function M.show_diff_for_file(file_path)
  local hooks = require('nvim-claude.hooks')
  local inline_diff = require('nvim-claude.inline-diff')
  local bufnr = vim.fn.bufnr(file_path)
  
  if bufnr == -1 then
    vim.cmd('edit ' .. file_path)
    bufnr = vim.fn.bufnr(file_path)
  end
  
  -- Get baseline content from stash
  local git_root = vim.fn.fnamemodify(M.test_dir, ':p')
  local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  
  local cmd = string.format('git show %s:%s', hooks.stable_baseline_ref, relative_path)
  local baseline_content = vim.fn.system(cmd)
  
  if vim.v.shell_error ~= 0 then
    baseline_content = ''
  end
  
  -- Get current content
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_content = table.concat(current_lines, '\n')
  
  -- Show diff directly
  inline_diff.show_inline_diff(bufnr, baseline_content, current_content)
  
  -- Make sure we're in the right window
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  end
end

-- Simulate Claude editing a file
function M.simulate_claude_edit(file_path, changes)
  local hooks = require('nvim-claude.hooks')
  
  -- Create baseline if needed
  hooks.pre_tool_use_hook('Edit', file_path)
  
  -- Apply changes
  local content = vim.fn.readfile(file_path)
  for _, change in ipairs(changes) do
    if change.action == 'modify' then
      content[change.line] = change.new_text
    elseif change.action == 'add' then
      table.insert(content, change.line, change.new_text)
    elseif change.action == 'delete' then
      table.remove(content, change.line)
    end
  end
  
  vim.fn.writefile(content, file_path)
  
  -- Track as edited
  hooks.post_tool_use_hook(file_path)
end

-- Wait for async operations
function M.wait_for(condition_fn, timeout_ms)
  timeout_ms = timeout_ms or 1000
  local start = vim.loop.now()
  
  while not condition_fn() do
    vim.cmd('sleep 10m')
    if vim.loop.now() - start > timeout_ms then
      error('Timeout waiting for condition')
    end
  end
end

-- Mock git command failures
function M.mock_git_failure(command_pattern)
  local original_system = vim.fn.system
  vim.fn.system = function(cmd, ...)
    if cmd:match(command_pattern) then
      vim.v.shell_error = 1
      return 'mocked git error'
    end
    return original_system(cmd, ...)
  end
  return function()
    vim.fn.system = original_system
  end
end

return M