# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Testing Changes
```bash
# Test plugin in Neovim (from parent directory)
nvim  # Plugin automatically handles server setup
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
4. `inline-diff.accept_current_hunk()` → Updates git baseline commit, saves state
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

- **Baseline Reference**: `persistence.get_baseline_ref()` - SHA of the baseline stash
- **Tracked Files**: `hooks.claude_edited_files` - Map of relative paths
- **Active Diffs**: `inline-diff.active_diffs[bufnr]` - Current diff data per buffer
- **Persistence**: JSON file containing stash ref and tracked files

State cleanup happens when:
- All hunks in a file are accepted/rejected → File removed from tracking
- All tracked files processed → Baseline cleared, persistence deleted

#### 4. Hook System Integration
The plugin integrates with Claude Code's hook system via `.claude/settings.local.json`:

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
4. Check baseline ref: `:lua print(require('nvim-claude.inline-diff-persistence').get_baseline_ref())`

### Critical Functions

#### `inline-diff.accept_current_hunk(bufnr)`
- Updates git baseline commit to include accepted changes
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

## Onboarding

### Quick Start for New Claude Instances

If you're a new Claude instance working on this codebase, here's what you need to know:

#### 1. Understanding the Core Purpose
This is a Neovim plugin that integrates with Claude Code (the CLI tool). It tracks changes Claude makes to files and displays them as inline diffs that users can accept or reject, similar to a code review interface within their editor.

#### 2. Key Concepts to Grasp First
- **Baseline Stashes**: The plugin creates git stashes as "snapshots" before Claude edits files. These serve as the baseline for showing diffs.
- **Single Baseline Reference**: The plugin uses a single source of truth for the baseline:
  - `persistence.current_stash_ref` (accessed via `get_baseline_ref()` and `set_baseline_ref()`)
- **Claude Edited Files**: Files that Claude has modified are tracked in `hooks.claude_edited_files`

#### 3. Common Gotchas
- **New Files**: Files that don't exist in the baseline stash will cause git errors. Always check for `fatal:` or `error:` in git command outputs.
- **Path Handling**: Always use `vim.pesc()` when escaping paths for pattern matching.
- **Persistence**: The plugin uses both global (`~/.local/share/nvim/`) and project-local (`.nvim-claude/`) persistence.
- **Error Handling**: `utils.exec()` returns output even on error - check both return values and content for error messages.

#### 4. Essential Files to Read First
1. `hooks.lua` - Start here. Contains the Claude Code integration and baseline management.
2. `inline-diff.lua` - Core diff display and accept/reject logic.
3. `inline-diff-persistence.lua` - How state is saved/loaded across sessions.

#### 5. Testing Workflow
```bash
# 1. Make changes to the plugin
# 2. In Neovim, reload the plugin:
:source lua/nvim-claude/init.lua

# 3. Test your changes:
:ClaudeDebugInlineDiff  # Shows current state
<leader>if              # Manual refresh diff
```

#### 6. Debugging Commands
```vim
" Check tracked files
:lua vim.inspect(require('nvim-claude.hooks').claude_edited_files)

" Check baseline reference
:lua print(require('nvim-claude.inline-diff-persistence').get_baseline_ref())

" View persistence state
:!cat .nvim-claude/inline-diff-state.json | jq
```

#### 7. Common Tasks

**Adding Debug Logging:**
```lua
logger.debug('function_name', 'Description', { key = value })
```

**Checking if a file exists in baseline:**
```lua
local baseline_content, err = utils.exec(string.format("git show %s:'%s' 2>/dev/null", stash_ref, file))
if err or not baseline_content or baseline_content:match('^fatal:') then
  -- File doesn't exist in baseline
end
```

**Updating baseline reference:**
```lua
-- Always use the persistence module
local persistence = require('nvim-claude.inline-diff-persistence')
persistence.set_baseline_ref(new_ref)
```

#### 8. Architecture Mental Model
Think of it as a three-layer system:
1. **Hook Layer**: Intercepts Claude's file operations (pre/post hooks)
2. **Diff Layer**: Computes and displays visual diffs in buffers
3. **Persistence Layer**: Saves state between Neovim sessions

The flow is: Claude edits → Hooks capture → Baseline created/updated → Diff displayed → User accepts/rejects → State persisted

#### 9. Key Invariants to Maintain
- If a file is in `claude_edited_files`, there must be a valid baseline reference
- The baseline reference must always point to a valid git commit/stash
- Accepting all hunks in a file should remove it from tracking
- Persistence should survive Neovim restarts

#### 10. Where to Look When Things Break
- **Diff not showing**: Check if baseline exists and contains the file
- **Stale diffs**: Ensure buffer is refreshed with `:checktime`
- **Persistence issues**: Check both baseline references are in sync
- **New file issues**: Look for error message handling in baseline retrieval

### Hook Debugging Methodology

When hooks aren't working as expected, follow this step-by-step debugging process:

#### 1. Check the Hook Logs
```bash
# View recent hook activity
tail -50 ~/.local/share/nvim/nvim-claude-hooks.log

# Search for specific file or command
tail -100 ~/.local/share/nvim/nvim-claude-hooks.log | grep -A5 -B5 "filename"
```

#### 2. Test nvr Commands Manually
Before debugging complex hook flows, test individual components:

```bash
# Test basic nvr connectivity
./scripts/nvr-proxy.sh --remote-expr "1+1"

# Test luaeval syntax
./scripts/nvr-proxy.sh --remote-expr 'luaeval("1+1")'

# Test requiring a module
./scripts/nvr-proxy.sh --remote-expr 'luaeval("require(\"nvim-claude.hooks\")")'

# Test specific functions (with TARGET_FILE for correct project)
TARGET_FILE="/path/to/file" ./scripts/nvr-proxy.sh --remote-expr 'luaeval("require(\"nvim-claude.hooks\").some_function()")'
```

#### 3. Debug Hook Command Construction
If hooks are failing, manually construct and test the exact command:

```bash
# Example: Test what the bash hook would send
ABS_PATH="/path/to/file"
ABS_PATH_ESCAPED=$(echo "$ABS_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
echo "Escaped path: $ABS_PATH_ESCAPED"
TARGET_FILE="$ABS_PATH" ./scripts/nvr-proxy.sh --remote-expr "luaeval(\"require('nvim-claude.hooks').track_deleted_file('$ABS_PATH_ESCAPED')\")"
```

#### 4. Check Module Loading
If functions appear to not exist:

```bash
# Force reload module and test
./scripts/nvr-proxy.sh -c "lua package.loaded['nvim-claude.hooks'] = nil; require('nvim-claude.hooks')"

# Check if function exists
./scripts/nvr-proxy.sh --remote-expr "luaeval(\"type(require('nvim-claude.hooks').function_name)\")"
```

#### 5. Trace Execution Flow
When debugging complex issues like deletion tracking:

1. **Verify hook is called**: Check logs for "Hook called at"
2. **Check command parsing**: Look for "Detected rm command" or similar
3. **Verify nvr execution**: Look for "Calling nvr-proxy with:"
4. **Check return values**: Look for exit codes and output
5. **Verify state changes**: Check `claude_edited_files` and baseline refs

```bash
# Check current state
./scripts/nvr-proxy.sh --remote-expr "luaeval(\"vim.inspect(require('nvim-claude.hooks').claude_edited_files)\")"
./scripts/nvr-proxy.sh --remote-expr "luaeval(\"require('nvim-claude.inline-diff-persistence').get_baseline_ref()\")"
```

#### 6. Common Hook Issues and Solutions

**"No valid expression" errors**:
- Usually means syntax error in the luaeval expression
- Check quoting and escaping
- Test simpler expressions first

**Function not found errors**:
- Module might not be loaded/reloaded
- Function might not be exported (check `return M` at end of module)
- Typo in function name

**Baseline not updating**:
- Check if baseline ref is valid: `git cat-file -t <ref>`
- Verify git commands aren't failing silently
- Check temp file/directory cleanup issues

**Files not being tracked**:
- Verify pre-hook creates/updates baseline
- Check if file exists in baseline
- Ensure relative paths are calculated correctly

#### 7. Hook Testing Workflow
```bash
# 1. Make changes to hook-related code
# 2. Reload plugin in Neovim
:source lua/nvim-claude/init.lua

# 3. Create test file through Claude (to trigger pre-hook)
# 4. Check logs immediately
tail -20 ~/.local/share/nvim/nvim-claude-hooks.log

# 5. Test the specific operation (edit/delete)
# 6. Verify state changes
:lua vim.inspect(require('nvim-claude.hooks').claude_edited_files)
```

## Coding Guidelines
- Always use single quotes instead of double quotes.

### Important Hints for Claude Code
- Hooks and anything passing strings to luaeval should use our base64 encoding strategy

```