# nvim-claude Debugging Guide

## Debug Logging

nvim-claude includes a comprehensive file-based logging system to help diagnose issues with inline diffs, hooks, agents, and other functionality.

### Log File Location

Debug logs are stored globally per project:

```
~/.local/share/nvim/nvim-claude/logs/<project-hash>-debug.log
```

Where `<project-hash>` is a hash of the project's absolute path.

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

The logging system tracks key operations:

1. **Hook Operations**:
   - Pre-tool-use hook calls (baseline creation)
   - Post-tool-use hook calls (file tracking)
   - User prompt submit hooks (checkpoint creation)
   - Bash command hooks

2. **State Management**:
   - State saving/loading operations
   - Missing baseline references
   - Corrupted state detection
   - Global state migration

3. **Git Operations**:
   - Baseline commit creation
   - Checkpoint commit creation
   - Git command results and errors
   - Working directory context

4. **Agent Operations**:
   - Agent creation and management
   - Worktree operations
   - Registry updates

5. **MCP Server**:
   - LSP diagnostic queries
   - Server communication

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

#### Issue: Tracked files with no baseline

If you see files tracked in `inline-diff-state.json` but no baseline reference:

1. Check the log for errors during stash creation:
   ```vim
   :ClaudeViewLog
   ```
   Look for entries like:
   - `[ERROR] [create_baseline] Git returned error message`
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
   - Verify baseline commit creation succeeded

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
1. Relevant portions of the debug log (run `:ClaudeViewLog`)
2. Debug information (run `:ClaudeDebugInlineDiff`)
3. Steps to reproduce the issue
4. Your Neovim version and OS

You can sanitize paths and project names if needed for privacy.