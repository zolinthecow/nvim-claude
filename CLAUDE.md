# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Testing Changes
```bash
# Test plugin in Neovim (from parent directory)
nvim --listen /tmp/nvim-server.pipe  # Required for hooks to work
:source lua/nvim-claude/init.lua     # Reload plugin
:ClaudeDebugInlineDiff               # Debug inline diff state
```

### Git Operations
```bash
# Create test stash for baseline
git stash create                     # Returns SHA hash
git stash store -m "message" <SHA>   # Store with message
git show <SHA>:path/to/file          # View file in stash
```

## Architecture Overview

### Core Systems

#### 1. Stash-Based Diff Tracking
The inline diff system uses git stashes as immutable baselines for tracking changes:

- **Baseline Creation**: When Claude first edits files, `hooks.pre_tool_use_hook()` creates a baseline stash
- **File Tracking**: `hooks.claude_edited_files` tracks which files Claude has modified (relative paths)
- **Diff Display**: When opening a tracked file, computes diff between baseline stash version and working directory
- **State Persistence**: `inline-diff-persistence.lua` saves state to `~/.local/share/nvim/nvim-claude-inline-diff-state.json`

Key functions flow:
1. `hooks.pre_tool_use_hook()` → Creates baseline stash if none exists
2. `hooks.post_tool_use_hook(file_path)` → Marks file as Claude-edited
3. `hooks.show_inline_diff_for_file()` → Retrieves baseline from stash, shows diff
4. `inline-diff.accept_current_hunk()` → Updates in-memory baseline, saves state
5. `inline-diff.reject_current_hunk()` → Applies reverse patch to working directory

#### 2. Module Dependencies
```
init.lua (entry point)
├── hooks.lua (Claude Code integration)
│   ├── inline-diff-persistence.lua (state management)
│   └── inline-diff.lua (diff visualization)
├── tmux.lua (chat interface)
├── commands.lua (user commands)
├── mappings.lua (keybindings)
└── git.lua (worktree management)
```

#### 3. State Management
The plugin maintains several types of state:

- **Baseline Reference**: `hooks.stable_baseline_ref` - SHA of the baseline stash
- **Tracked Files**: `hooks.claude_edited_files` - Map of relative paths
- **Active Diffs**: `inline-diff.active_diffs[bufnr]` - Current diff data per buffer
- **Persistence**: JSON file containing stash ref and tracked files

State cleanup happens when:
- All hunks in a file are accepted/rejected → File removed from tracking
- All tracked files processed → Baseline cleared, persistence deleted

#### 4. Hook System Integration
The plugin integrates with Claude Code's hook system via `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": { "matcher": "Edit|Write|MultiEdit", "command": "nvr --remote-expr..." },
    "PostToolUse": { "matcher": "Edit|Write|MultiEdit", "command": "nvr --remote-send..." }
  }
}
```

Hooks use `nvr` (neovim-remote) to communicate with the running Neovim instance.

### Key Implementation Details

#### SHA vs Stash References
- Always use SHA hashes (e.g., `8b0902ed0df...`) instead of `stash@{0}`
- `inline-diff-persistence.create_stash()` returns SHA directly
- Validation handles both formats for backward compatibility

#### File Path Handling
- Always use `file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')` for relative paths
- Never use `file_path:sub(#git_root + 2)` which breaks with special characters

#### Diff Computation
- Uses `git diff --no-index --unified=3 --diff-algorithm=histogram`
- Writes content to temp files in `/tmp/nvim-claude-*.txt`
- Parses unified diff format into hunk structures

#### Visual Indicators
- Uses Neovim's extmark API for virtual text and highlights
- Deletions shown as virtual lines above with `DiffDelete` highlight
- Additions highlighted with `DiffAdd` on actual lines
- Signs in gutter: `>` for additions, `~` for changes

### Common Patterns

#### Adding a New Command
1. Define function in appropriate module (e.g., `inline-diff.lua`)
2. Add command in `commands.lua` using `vim.api.nvim_create_user_command`
3. Add keymap in `mappings.lua` or `setup_inline_keymaps()`
4. Update README.md with new command/keymap

#### Debugging State Issues
1. Check persistence file: `cat ~/.local/share/nvim/nvim-claude-inline-diff-state.json | jq`
2. Check stash exists: `git stash list | grep nvim-claude`
3. Verify tracked files: `:lua vim.inspect(require('nvim-claude.hooks').claude_edited_files)`
4. Check baseline ref: `:lua print(require('nvim-claude.hooks').stable_baseline_ref)`

### Critical Functions

#### `inline-diff.accept_current_hunk(bufnr)`
- Updates in-memory baseline to current state
- Removes file from tracking if no diffs remain
- Saves persistence state

#### `inline-diff.reject_current_hunk(bufnr)`
- Generates patch for the hunk
- Applies patch in reverse using `git apply --reverse`
- Recalculates diff against unchanged baseline

#### `hooks.show_inline_diff_for_file(buf, file, git_root, stash_ref)`
- Retrieves baseline content: `git show <stash_ref>:<file>`
- Gets current buffer content
- Calls `inline-diff.show_inline_diff()` with both contents

#### `inline-diff-persistence.save_state(diff_data)`
- Saves current tracking state to JSON
- Includes stash ref, tracked files, and active diff data
- Called on VimLeavePre and after accept/reject operations
