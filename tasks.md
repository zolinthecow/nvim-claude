# nvim-claude Debug Tasks

## ✅ Immediate Issues Resolved!

### Completed Tasks

- ✅ **COMPLETED**: Baseline stash management - Now properly handles per-file baselines and new files
- ✅ **COMPLETED**: `<leader>ci` refresh - Now immediately shows newly edited files  
- ✅ **COMPLETED**: Ghost diff at end of files - Fixed newline inconsistencies causing phantom hunks

### Summary

All major debugging tasks have been completed. The plugin is working as intended for daily use! 🎉

---

## 🔧 Backlog Issues (Future Hardening)

### Priority 1: Critical Security & Reliability

#### 1. Shell Injection Vulnerabilities in Git Commands
**Priority**: Critical  
**Files**: `hooks.lua`, `inline-diff.lua`, `inline-diff-persistence.lua`

**Problem**: File paths are used directly in shell commands without proper escaping, creating potential shell injection vulnerabilities.

**Specific Locations**:
- `hooks.lua:265`: `local cmd = string.format('cd "%s" && git show %s:%s', git_root, stash_ref, file)`
- `hooks.lua:290-295`: Multiple git commands using unescaped file paths
- `inline-diff.lua:75-78`: `git diff` command with file paths
- `inline-diff-persistence.lua:88`: `git stash list | grep nvim-claude`

**Code Example of Problem**:
```lua
-- Current unsafe approach in hooks.lua:265
local cmd = string.format('cd "%s" && git show %s:%s', git_root, stash_ref, file)
-- If file contains special chars like `;rm -rf /`, this becomes dangerous
```

**Solution Needed**: 
1. Create a `shell_escape()` utility function that properly escapes all file paths
2. Replace all instances of direct string interpolation with escaped paths
3. Use array-style command execution where possible instead of shell strings

#### 2. Atomic Git Operations in update_baseline_for_file()
**Priority**: Critical  
**File**: `hooks.lua:177-341`

**Problem**: The `update_baseline_for_file()` function performs complex multi-step git operations without atomicity. If any step fails mid-process, the baseline state becomes corrupted.

**Specific Code Block**:
```lua
-- hooks.lua:215-331 - Multi-step operation without rollback
local function update_tree_with_file(tree_hash, file_path, blob_hash, git_root)
  -- Step 1: Read existing tree
  local tree_cmd = string.format('cd "%s" && git ls-tree %s', git_root, tree_hash)
  
  -- Step 2: Create new tree object
  local mktree_cmd = string.format('cd "%s" && git mktree', git_root)
  
  -- Step 3: Create commit
  local commit_cmd = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', ...)
  
  -- Problem: Any of these can fail, leaving system in inconsistent state
end
```

**Solution Needed**:
1. Wrap the entire operation in a transaction-like structure
2. Validate each git command's success before proceeding
3. Implement rollback mechanism if any step fails
4. Add comprehensive error logging for each git operation

#### 3. Race Conditions in Hook System
**Priority**: High  
**Files**: `hooks.lua`, `pre-hook-wrapper.sh`

**Problem**: Pre-hook and post-hook can execute concurrently or in unexpected order, leading to state inconsistencies.

**Specific Issues**:
- `hooks.lua:110-150`: Pre-hook baseline creation not atomic with file tracking
- `hooks.lua:400-420`: Post-hook file tracking happens independently of pre-hook
- No locking mechanism to prevent concurrent hook execution

**Solution Needed**:
1. Add file-based locking mechanism during hook operations
2. Ensure pre-hook completes before post-hook begins processing
3. Add sequence validation to detect out-of-order hook execution

### Priority 2: Reliability & Error Handling

#### 4. Silent Git Operation Failures
**Priority**: High  
**Files**: `inline-diff.lua`, `hooks.lua`, `inline-diff-persistence.lua`

**Problem**: Many git operations fail silently or log errors but continue execution as if nothing happened.

**Specific Examples**:
- `inline-diff.lua:480-487`: Patch application failures logged but not handled
- `hooks.lua:265-275`: `git show` failures for missing files not properly handled
- `inline-diff-persistence.lua:96-102`: Stash validation clears all state on any error

**Code Example**:
```lua
-- inline-diff.lua:480-487 - Silent failure continuation
local result, err = utils.exec(cmd)
if err or (result and result:match('error:')) then
  vim.notify('Failed to reject hunk: ' .. (err or result), vim.log.levels.ERROR)
  -- Function continues as if patch was applied successfully!
  return
end
```

**Solution Needed**:
1. Add proper return value checking for all git operations
2. Implement graceful fallback behaviors for common failure modes
3. Add retry mechanisms for transient failures
4. Prevent state updates when operations fail

#### 5. State Inconsistency Between Modules
**Priority**: Medium  
**Files**: `hooks.lua`, `inline-diff.lua`

**Problem**: Two separate tracking systems can get out of sync: `hooks.claude_edited_files` vs `inline_diff.diff_files`.

**Specific Locations**:
- `hooks.lua:400-420`: Updates `claude_edited_files` and `diff_files` separately
- `inline-diff.lua:19-22`: Independently manages `diff_files` state
- No validation that both tracking systems remain consistent

**Solution Needed**:
1. Centralize file tracking in a single module
2. Add state validation functions that can detect inconsistencies
3. Implement automatic state repair mechanisms

#### 6. Resource Leaks and Cleanup Issues
**Priority**: Medium  
**Files**: `inline-diff.lua`, multiple modules

**Problem**: Temporary files, extmarks, and virtual text not consistently cleaned up.

**Specific Issues**:
- `inline-diff.lua:68-72`: Temp files `/tmp/nvim-claude-*.txt` created but cleanup depends on function success
- Extmarks and virtual text may accumulate if buffers are closed unexpectedly
- Event handlers not always properly removed

**Solution Needed**:
1. Implement comprehensive cleanup on buffer close/plugin unload
2. Add auto-cleanup of temp files using Neovim's autocmds
3. Track and clean up all extmarks/virtual text on state changes

### Priority 3: Edge Case Handling

#### 7. Git Repository Edge Cases
**Priority**: Low  
**Files**: `hooks.lua`, `git.lua`

**Problem**: Plugin assumes standard git repository structure and may break in edge cases.

**Edge Cases to Handle**:
- Git worktrees where stash is in different repository
- Repositories with no commits (new repos)
- Submodules with independent git histories
- Repositories with custom git hooks that interfere

**Solution Needed**:
1. Add git repository type detection
2. Implement fallback behaviors for non-standard repositories
3. Add compatibility checks during plugin initialization

#### 8. Large File and Performance Issues
**Priority**: Low  
**Files**: `inline-diff.lua`, `utils.lua`

**Problem**: No limits on file sizes processed, could cause memory issues with very large files.

**Solution Needed**:
1. Add file size limits for diff processing
2. Implement streaming/chunked processing for large files
3. Add performance monitoring and warnings

#### 9. Hook Communication Issue with .nvim-server
**Priority**: Low  
**File**: `.nvim-server`

**Problem**: Sometimes `.nvim-server` contains an incorrect value like `/tmp/nvimsocket` instead of the actual nvim server address, causing hooks to fail silently.

**Current Issue**:
- The hook system relies on `.nvim-server` containing the correct server address
- When it contains a wrong value, hooks don't communicate with the running nvim instance
- This causes inline diff tracking to fail without obvious error messages

**Fix Required**:
- Add validation when reading `.nvim-server` to ensure it's a valid socket
- Add error handling to detect when nvr commands fail due to bad server address
- Consider alternative methods to discover the correct nvim server address
- Add diagnostic messages when hook communication fails

#### 10. **CRITICAL BUG**: Accept Hunk Accepts All Changes
**Priority**: Critical - **RESOLVED**  
**File**: `inline-diff.lua:515-643`

**Problem**: The `accept_current_hunk()` function is fundamentally broken. Instead of accepting only the current hunk, it accepts ALL changes by comparing current file content against itself.

**Current Broken Logic**:
```lua
-- inline-diff.lua:408-418 - Compares current content against itself
local current_content = table.concat(current_lines, '\n')
local new_diff_data = M.compute_diff(current_content, current_content) -- Always no diff!
-- Result: All changes accepted, file removed from tracking
```

**Required Fix**:
1. Generate patch for ONLY the current hunk
2. Apply that patch to the baseline stash version  
3. Update the stash baseline with the patched version using `hooks.update_baseline_for_file()` logic
4. Recompute diff against the updated baseline
5. Update `M.active_diffs[bufnr]` with new diff data
6. Re-render visualization for remaining hunks
7. Only remove from tracking if NO hunks remain
8. Auto-navigate to next hunk after acceptance

#### 10. Diff Data Never Refreshes After Baseline Updates
**Priority**: High  
**Files**: `inline-diff.lua`, `hooks.lua`

**Problem**: `M.active_diffs[bufnr]` is calculated once when file opens but never refreshed when baseline changes or buffer content changes.

**Issues**:
- Accept/reject operations update baseline stash but not in-memory diff data
- Buffer edits by user don't trigger diff recalculation
- Stale diff data causes incorrect hunk display

**Solution Needed**:
1. Refresh `M.active_diffs[bufnr]` after baseline updates
2. Consider auto-refresh on buffer content changes
3. Add manual refresh command for debugging

#### 11. Buffer Refresh for Open Files When Claude Edits
**Priority**: N/A - **ALREADY IMPLEMENTED**  
**File**: `hooks.lua:371-388`

**Implementation**: The post-hook already handles this case. When Claude edits a file:
1. Loops through all open buffers to find matching file path
2. Calls `vim.cmd('checktime')` to refresh buffer from disk
3. Automatically shows inline diff if baseline exists

**Code Reference**:
```lua
-- hooks.lua:371-388 - Already handles buffer refresh
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if buf_name == file_path then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('checktime')  -- Refresh buffer
    end)
    -- Show inline diff
    M.show_inline_diff_for_file(buf, relative_path, git_root, M.stable_baseline_ref)
  end
end
```

### Implementation Notes

When working on these issues:
1. **Always test edge cases** - Create test files with special characters, very long paths, etc.
2. **Add comprehensive logging** - Use `vim.log.levels.DEBUG` for operation tracking
3. **Maintain backward compatibility** - Existing state files should continue to work
4. **Document security considerations** - Any new shell command usage needs security review
