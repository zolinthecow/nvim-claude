# File Deletion Tracking Implementation Plan

## Overview
Add support for tracking, displaying, and reverting files deleted by Claude using `rm` commands.

## Implementation Tasks

### 1. Create Bash Hook Infrastructure
- [ ] Create `bash-hook-wrapper.sh` that captures bash commands
  - Parse JSON input to extract the command from `tool_input.command`
  - Detect if command starts with `rm`
  - If rm command, parse out file paths and send to Neovim
- [ ] Add bash hook configuration to hook installation/uninstallation scripts
  - Update `install_hooks.lua` to add Bash PostToolUse hook
  - Update settings template to include the new hook

### 2. Add Deletion Tracking to hooks.lua
- [ ] Create `M.post_bash_tool_use_hook(command)` function that:
  - Parses rm commands to extract file paths
  - Handles various rm patterns:
    - `rm file.txt` - simple case
    - `rm -rf dir/` - recursive directory deletion
    - `rm -f file1.txt file2.txt` - multiple files
    - `rm *.txt` - glob patterns (need to expand)
  - For each deleted file:
    - Check if file existed in baseline stash
    - Add to `claude_edited_files` map (same as edited files)
    - Add to `session_edited_files` for stop hook
  - Save persistence state

### 3. Update File Open Behavior
- [ ] Modify the BufReadPost autocmd in `hooks.lua`:
  - When opening a Claude-tracked file, check if it exists on disk
  - If file doesn't exist:
    - Create a scratch buffer instead
    - Set buffer name to include `[DELETED]` marker
    - Load baseline content and show as deletion diff
  - If file exists, show normal diff as before

### 4. Update ClaudeInlineDiffList Display
- [ ] Modify `inline-diff.list_diff_files()` to check file existence:
  - For each file in `claude_edited_files`
  - Check if file exists on disk
  - If not, add `[DELETED]` prefix to the display name
  - No need for separate deleted files tracking

### 5. Implement Deletion Diff Display
- [ ] Modify `show_inline_diff_for_file()` to handle non-existent files:
  - Detect when file doesn't exist
  - Create scratch buffer: `vim.api.nvim_create_buf(false, true)`
  - Set appropriate buffer name
  - Get baseline content from stash
  - Call `show_inline_diff()` with baseline content and empty string
  - This will show entire file as red deletions

### 6. Enable Restoration
- [ ] Ensure existing reject commands work with deleted files:
  - `<leader>iR` (reject all) should create the file and write baseline content
  - `<leader>ia` (accept all) should remove from tracking
- [ ] The existing `reject_all_hunks` should already handle this correctly

### 7. Handle Edge Cases
- [ ] Directory deletions (`rm -rf dir/`):
  - Need to list all files in directory from baseline stash
  - Track each file individually
- [ ] Glob patterns (`rm *.txt`):
  - Option 1: Run the glob in a safe way to see what would be deleted
  - Option 2: Compare baseline file list before/after the command
- [ ] Files that don't exist (rm fails):
  - Check command output/return code
  - Only track if deletion succeeded

### 8. Testing Plan
- [ ] Test simple file deletion: `rm test.txt`
- [ ] Test multiple files: `rm file1.txt file2.txt`
- [ ] Test with flags: `rm -f test.txt`
- [ ] Test directory deletion: `rm -rf test-dir/`
- [ ] Test glob patterns: `rm *.tmp`
- [ ] Test restoration via reject commands
- [ ] Test persistence across Neovim restarts
- [ ] Test stop hook includes deleted files

## Technical Considerations

### Debug Test Edit
Testing baseline creation after accepting all changes.

### Command Parsing Strategy
```bash
# Extract command from JSON
COMMAND=$(echo "$JSON_INPUT" | jq -r '.tool_input.command')

# Check if it's an rm command
if [[ "$COMMAND" =~ ^rm[[:space:]] ]]; then
  # Parse out flags and files
  # Handle quotes, escapes, etc.
fi
```

### Glob Expansion
For commands like `rm *.txt`, we need to:
1. Either expand the glob ourselves (risky)
2. Or check what files were deleted by comparing baseline before/after

### Performance
- Parsing bash commands adds overhead to every bash operation
- Consider caching baseline file listings for faster deletion detection
- Batch multiple deletions in same command

## Alternative Approaches Considered

1. **Add Delete tool to Claude Code**: Rejected as too complex to maintain
2. **Detect deletions on-the-fly**: Would catch user deletions too
3. **Hook into filesystem events**: Platform-specific and complex
4. **Check git status**: Would miss files not tracked by git

## Success Criteria
- [ ] Deleted files appear in `<leader>ci` with clear indication
- [ ] Can view deletion diff (all red)
- [ ] Can restore deleted files with reject commands
- [ ] Deletions persist across Neovim sessions
- [ ] Stop hook catches errors in deleted files
- [ ] No false positives from user deletions