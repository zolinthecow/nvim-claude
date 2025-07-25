# nvim-claude Debugging Guide

## Debug Logging

nvim-claude includes a file-based logging system to help diagnose issues, particularly with the inline diff functionality.

### Log File Location

The debug log is stored in one of two locations:

1. **Project-specific log** (when in a git repository):
   ```
   <project_root>/.nvim-claude/debug.log
   ```

2. **Global fallback log** (when not in a git repository):
   ```
   ~/.local/share/nvim/nvim-claude-debug.log
   ```

### Viewing Logs

Use the following commands to work with logs:

- **View the current log file**:
  ```vim
  :ClaudeViewLog
  ```
  This opens the log file in a new buffer and jumps to the end.

- **Clear the log file**:
  ```vim
  :ClaudeClearLog
  ```
  This empties the log file to start fresh.

### What Gets Logged

The logging system tracks key operations related to inline diffs:

1. **Hook Operations**:
   - Pre-tool-use hook calls (baseline creation)
   - Post-tool-use hook calls (file tracking)
   - Git operations (stash creation, errors)

2. **State Management**:
   - State saving/loading operations
   - Missing stash_ref warnings
   - Corrupted state detection

3. **Git Operations**:
   - Stash creation attempts
   - Git command results and errors
   - Working directory context

### Log Format

Each log entry includes:
- **Timestamp**: When the event occurred
- **Level**: DEBUG, INFO, WARN, or ERROR
- **Component**: Which module logged the message
- **Message**: Description of the event
- **Data**: Additional context (when applicable)

Example:
```
[2024-01-15 10:30:45] [INFO] [pre_tool_use_hook] Creating baseline stash
  Data: {
    stash_ref = "8b0902ed0df3c1b7a9f5e2d4b6c8e9f0a1b2c3d4",
    cwd = "/Users/user/project"
  }
```

### Debugging Common Issues

#### Issue: Tracked files with no baseline stash

If you see files tracked in `inline-diff-state.json` but no `stash_ref`:

1. Check the log for errors during stash creation:
   ```vim
   :ClaudeViewLog
   ```
   Look for entries like:
   - `[ERROR] [create_stash] Git returned error message`
   - `[ERROR] [post_tool_use_hook] No baseline ref when saving state!`

2. Common causes:
   - Not in a git repository when Claude edits files
   - Git operation failures (permissions, disk space)
   - Race conditions between pre and post hooks

3. To reset corrupted state:
   ```vim
   :ClaudeResetInlineDiff
   ```

#### Issue: Inline diffs not showing

1. Check if files are being tracked:
   ```vim
   :ClaudeDebugInlineDiff
   ```

2. Review the log for hook execution:
   - Look for `pre_tool_use_hook` entries
   - Check for `post_tool_use_hook` entries
   - Verify stash creation succeeded

### Log Rotation

The log file automatically rotates when it exceeds 10MB to prevent disk space issues. The previous log is saved as `debug.log.old`.

### Privacy Note

The debug log may contain:
- File paths and names
- Git commit hashes
- Error messages

It does not contain:
- File contents
- Sensitive data from your code

### Reporting Issues

When reporting bugs, please include:
1. Relevant portions of the debug log
2. The contents of `.nvim-claude/inline-diff-state.json`
3. Steps to reproduce the issue

You can sanitize paths and project names if needed for privacy.