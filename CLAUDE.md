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
# View baseline commit
git show refs/nvim-claude/baseline   # Show baseline commit
git show refs/nvim-claude/baseline:path/to/file  # View file in baseline

# View checkpoints
git for-each-ref refs/nvim-claude/checkpoints/  # List all checkpoints
git show refs/nvim-claude/checkpoints/<id>     # Show checkpoint commit
```

## Architecture Overview

### Core Systems

#### 1. Commit-Based Diff Tracking
The inline diff system uses git commits as immutable baselines for tracking changes:

- **Baseline Creation**: When Claude first edits files, `hooks.pre_tool_use_hook()` creates a baseline commit
- **File Tracking**: `hooks.claude_edited_files` tracks which files Claude has modified (relative paths)
- **Diff Display**: When opening a tracked file, computes diff between baseline commit version and working directory
- **State Persistence**: `inline-diff-persistence.lua` saves state globally via `project-state.lua`
- **Baseline Storage**: Commits are stored in git ref `refs/nvim-claude/baseline`

Key functions flow:
1. `hooks.pre_tool_use_hook()` → Creates baseline commit if none exists
2. `hooks.post_tool_use_hook(file_path)` → Marks file as Claude-edited
3. `hooks.show_inline_diff_for_file()` → Retrieves baseline from commit, shows diff
4. `inline-diff.accept_current_hunk()` → Updates git baseline commit, saves state
5. `inline-diff.reject_current_hunk()` → Applies reverse patch to working directory

#### 2. Module Dependencies
```
init.lua (entry point)
├── hooks.lua (Claude Code integration)
│   ├── inline-diff-persistence.lua (state management)
│   ├── inline-diff.lua (diff visualization)
│   └── inline-diff-debug.lua (debug utilities)
├── project-state.lua (global state storage)
├── tmux.lua (chat interface)
├── commands.lua (user commands)
├── mappings.lua (keybindings)
├── git.lua (worktree management)
├── checkpoint.lua (checkpoint system)
├── registry.lua (agent registry)
├── agent-viewer.lua (agent viewing)
├── mcp-bridge.lua (MCP server integration)
├── settings-updater.lua (settings management)
├── statusline.lua (status line integration)
├── diff-review.lua (diff review UI)
├── logger.lua (logging system)
└── utils.lua (utility functions)
```

#### 3. State Management
The plugin maintains several types of state:

- **Baseline Reference**: `persistence.get_baseline_ref()` - SHA of the baseline commit
- **Tracked Files**: `hooks.claude_edited_files` - Map of relative paths  
- **Active Diffs**: `inline-diff.active_diffs[bufnr]` - Current diff data per buffer
- **Persistence Locations** (all stored globally):
  - Inline diff state: `~/.local/share/nvim/nvim-claude/projects/<path-hash>/inline-diff-state.json`
  - Agent registry: `~/.local/share/nvim/nvim-claude/projects/<path-hash>/agent-registry.json`
  - Debug logs: `~/.local/share/nvim/nvim-claude/logs/<path-hash>-debug.log`
  - Server file: `/tmp/nvim-claude-<path-hash>-server` (or `$XDG_RUNTIME_DIR`)
- **Checkpoint Data**: Stored as git commits with refs `refs/nvim-claude/checkpoints/*`

State cleanup happens when:
- All hunks in a file are accepted/rejected → File removed from tracking
- All tracked files processed → Baseline cleared, persistence deleted
- Project deleted → Use `:ClaudeCleanupProjects` to remove orphaned state

#### 4. Hook System Integration
The plugin integrates with Claude Code's hook system via `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [{
        "type": "command",
        "command": "/path/to/plugin/scripts/pre-hook-wrapper.sh"
      }]
    }],
    "PostToolUse": [{
      "matcher": "Edit|Write|MultiEdit", 
      "hooks": [{
        "type": "command",
        "command": "/path/to/plugin/scripts/post-hook-wrapper.sh"
      }]
    }],
    "UserPromptSubmit": [{
      "hooks": [{
        "type": "command",
        "command": "/path/to/plugin/scripts/user-prompt-hook-wrapper.sh"
      }]
    }]
  }
}
```

Hooks use wrapper scripts that handle base64 encoding and call `nvim-rpc.sh` (Python-based RPC client using pynvim) to communicate with the running Neovim instance.

### Key Implementation Details

#### Commit References
- Baselines are stored as git commits with SHA hashes (e.g., `8b0902ed0df...`)
- `inline-diff-persistence.create_baseline()` creates a commit and returns its SHA
- Commits are stored in custom git ref: `refs/nvim-claude/baseline`
- The term "stash_ref" is still used in code for backward compatibility but refers to commit SHAs

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
1. Check persistence file: `cat ~/.local/share/nvim/nvim-claude/projects/<path-hash>/inline-diff-state.json | jq`
2. Check baseline commit exists: `git show refs/nvim-claude/baseline`
3. Verify tracked files: `:lua vim.inspect(require('nvim-claude.hooks').claude_edited_files)`
4. Check baseline ref: `:lua print(require('nvim-claude.inline-diff-persistence').get_baseline_ref())`
5. View all nvim-claude refs: `git for-each-ref refs/nvim-claude/`

### Critical Functions

#### `inline-diff.accept_current_hunk(bufnr)`
- Updates git baseline commit to include accepted changes
- Removes file from tracking if no diffs remain
- Saves persistence state

#### `inline-diff.reject_current_hunk(bufnr)`
- Generates patch for the hunk
- Applies patch in reverse using `git apply --reverse`
- Recalculates diff against unchanged baseline

#### `hooks.show_inline_diff_for_file(buf, file, git_root, baseline_ref)`
- Retrieves baseline content: `git show <baseline_ref>:<file>`
- Gets current buffer content
- Calls `inline-diff.show_inline_diff()` with both contents

#### `inline-diff-persistence.save_state(diff_data)`
- Saves current tracking state to JSON
- Includes baseline ref, tracked files, and active diff data
- Called on VimLeavePre and after accept/reject operations

### New Features Not Yet Documented

#### Checkpoint System
- Save/restore work states independent of baselines
- Commands: `:ClaudeCheckpoints`, `:ClaudeCheckpointCreate`, etc.
- Stored as git commits in `refs/nvim-claude/checkpoints/*`

#### Background Agents
- Run Claude in isolated git worktrees
- Project-specific agent registry
- Commands: `:ClaudeBg`, `:ClaudeAgents`, `:ClaudeKillAll`

#### MCP Server Integration (Headless Neovim Architecture)
- Provides LSP diagnostics to Claude via isolated headless Neovim instance
- Install with `:ClaudeInstallMCP` (auto-installs Python env and registers with Claude Code)
- Requires Python 3.10+ and pynvim

- **Architecture**: Headless Neovim instance runs separately from main editor
  - **Simple init approach**: Uses `-u ~/.config/nvim/init.lua` directly (no custom init files)
  - **Real file paths**: Creates buffers with actual file paths for proper LSP attachment
  - **Fixed timing**: 3-second diagnostic wait instead of complex event-driven waits
  - **Generic LSP support**: Works with any LSP servers (not hardcoded to specific ones)
  - Communicates via subprocess using pynvim (no event loop conflicts)
  - Stop hook also uses this headless instance for error checking

- **Key Benefits**: 
  - Zero UI freezing when Claude accesses diagnostics
  - No buffer modifications in user's active editor
  - Thread-safe subprocess isolation
  - Works reliably with TypeScript, Biome, and other LSP servers

- **Historical Note**: Originally used complex custom init files and event-driven diagnostic waiting, 
  but this caused subtle issues where TypeScript diagnostics wouldn't work. The current simple 
  approach mirrors a normal Neovim session and is much more reliable.

#### Status Line Integration
- Shows active diff count in status line
- Integrates with popular status line plugins

## Onboarding

### Quick Start for New Claude Instances

If you're a new Claude instance working on this codebase, here's what you need to know:

#### 1. Understanding the Core Purpose
This is a Neovim plugin that integrates with Claude Code (the CLI tool). It tracks changes Claude makes to files and displays them as inline diffs that users can accept or reject, similar to a code review interface within their editor.

#### 2. Key Concepts to Grasp First
- **Baseline Commits**: The plugin creates git commits as "snapshots" before Claude edits files. These serve as the baseline for showing diffs.
- **Single Baseline Reference**: The plugin uses a single source of truth for the baseline:
  - `persistence.current_stash_ref` (accessed via `get_baseline_ref()` and `set_baseline_ref()`)
  - Despite the name, this stores commit SHAs, not stash references
- **Claude Edited Files**: Files that Claude has modified are tracked in `hooks.claude_edited_files`
- **Checkpoint System**: Separate from baselines, allows saving/restoring work states

#### 3. Common Gotchas
- **New Files**: Files that don't exist in the baseline commit will cause git errors. Always check for `fatal:` or `error:` in git command outputs.
- **Path Handling**: Always use `vim.pesc()` when escaping paths for pattern matching.
- **Persistence**: The plugin uses global storage in `~/.local/share/nvim/nvim-claude/`.
- **Error Handling**: `utils.exec()` returns output even on error - check both return values and content for error messages.
- **Baseline vs Checkpoints**: Baselines track Claude's edits; checkpoints save user work states.

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
:!cat ~/.local/share/nvim/nvim-claude/projects/*/inline-diff-state.json | jq
```

#### 7. Common Tasks

**Adding Debug Logging:**
```lua
logger.debug('function_name', 'Description', { key = value })
```

**Checking if a file exists in baseline:**
```lua
local baseline_content, err = utils.exec(string.format("git show %s:'%s' 2>/dev/null", baseline_ref, file))
if err or not baseline_content or baseline_content:match('^fatal:') then
  -- File doesn't exist in baseline commit
end
```

**Updating baseline reference:**
```lua
-- Always use the persistence module
local persistence = require('nvim-claude.inline-diff-persistence')
persistence.set_baseline_ref(new_ref)
```

#### 8. Architecture Mental Model
Think of it as a multi-layer system:
1. **Hook Layer**: Intercepts Claude's file operations (pre/post hooks)
2. **Diff Layer**: Computes and displays visual diffs in buffers
3. **Persistence Layer**: Saves state between Neovim sessions
4. **Checkpoint Layer**: Manages save points for work in progress
5. **Agent Layer**: Manages background Claude instances in git worktrees
6. **MCP Layer**: Provides LSP diagnostics via headless Neovim instance
   - Headless instance loads user config but skips UI-related operations
   - Stop hook delegates diagnostic checks to MCP bridge
   - All diagnostic operations run outside main editor event loop

The flow is: Claude edits → Hooks capture → Baseline commit created/updated → Diff displayed → User accepts/rejects → State persisted

For diagnostics: Claude requests diagnostics → MCP server spawns headless Neovim → Loads files in temp buffers → LSP attaches → Returns diagnostics → Headless instance cleaned up

#### 9. Key Invariants to Maintain
- If a file is in `claude_edited_files`, there must be a valid baseline reference
- The baseline reference must always point to a valid git commit
- Accepting all hunks in a file should remove it from tracking
- Persistence should survive Neovim restarts
- Agent registry is project-specific, not global
- Checkpoints are separate from baselines and stored as git commits
- Headless Neovim must not write server files (checks `vim.g.headless_mode`)
- Stop hook must use MCP bridge for diagnostics (never create buffers in main instance)
- LSP diagnostics use `bufadd(full_path)` not unnamed buffers for proper LSP attachment

#### 10. Where to Look When Things Break
- **Diff not showing**: Check if baseline exists and contains the file
- **Stale diffs**: Ensure buffer is refreshed with `:checktime`
- **Persistence issues**: Check both baseline references are in sync
- **New file issues**: Look for error message handling in baseline retrieval
- **LSP diagnostics not working**:
  - Check if headless Neovim is running: `ps aux | grep nvim-claude-headless`
  - Verify pynvim installed: `~/.local/share/nvim/nvim-claude/mcp-env/bin/pip list | grep pynvim`
  - Check server file not overwritten: `cat /tmp/nvim-claude-*-server`
  - Debug logs: `/tmp/nvim-claude-mcp-debug.log` (if debug logging enabled)
- **Stop hook not triggering**:
  - Check `/tmp/stop-hook-debug.log` for diagnostic counts
  - Verify MCP server is running and accessible
  - Ensure `get_session_diagnostic_counts()` uses MCP bridge

### Hook Debugging Methodology

When hooks aren't working as expected, follow this step-by-step debugging process:

#### 1. Check the Hook Logs
```bash
# View recent hook activity
tail -50 ~/.local/share/nvim/nvim-claude-hooks.log

# Search for specific file or command
tail -100 ~/.local/share/nvim/nvim-claude-hooks.log | grep -A5 -B5 "filename"
```

#### 2. Test nvim-rpc Commands Manually
Before debugging complex hook flows, test individual components:

```bash
# Test basic nvim-rpc connectivity
./scripts/nvim-rpc.sh --remote-expr "1+1"

# Test luaeval syntax
./scripts/nvim-rpc.sh --remote-expr 'luaeval("1+1")'

# Test requiring a module
./scripts/nvim-rpc.sh --remote-expr 'luaeval("require(\"nvim-claude.hooks\")")'

# Test specific functions (with TARGET_FILE for correct project)
TARGET_FILE="/path/to/file" ./scripts/nvim-rpc.sh --remote-expr 'luaeval("require(\"nvim-claude.hooks\").some_function()")'
```

#### 3. Debug Hook Command Construction
If hooks are failing, manually construct and test the exact command:

```bash
# Example: Test what the bash hook would send
ABS_PATH="/path/to/file"
ABS_PATH_ESCAPED=$(echo "$ABS_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
echo "Escaped path: $ABS_PATH_ESCAPED"
TARGET_FILE="$ABS_PATH" ./scripts/nvim-rpc.sh --remote-expr "luaeval(\"require('nvim-claude.hooks').track_deleted_file('$ABS_PATH_ESCAPED')\")"
```

#### 4. Check Module Loading
If functions appear to not exist:

```bash
# Force reload module and test
./scripts/nvim-rpc.sh -c "lua package.loaded['nvim-claude.hooks'] = nil; require('nvim-claude.hooks')"

# Check if function exists
./scripts/nvim-rpc.sh --remote-expr "luaeval(\"type(require('nvim-claude.hooks').function_name)\")"
```

#### 5. Trace Execution Flow
When debugging complex issues like deletion tracking:

1. **Verify hook is called**: Check logs for "Hook called at"
2. **Check command parsing**: Look for "Detected rm command" or similar
3. **Verify nvim-rpc execution**: Look for "Calling nvim-rpc with:"
4. **Check return values**: Look for exit codes and output
5. **Verify state changes**: Check `claude_edited_files` and baseline refs

```bash
# Check current state
./scripts/nvim-rpc.sh --remote-expr "luaeval(\"vim.inspect(require('nvim-claude.hooks').claude_edited_files)\")"
./scripts/nvim-rpc.sh --remote-expr "luaeval(\"require('nvim-claude.inline-diff-persistence').get_baseline_ref()\")"
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

## Key Learnings and Development Philosophy

### 1. Simplicity Over Complexity

**Core Principle**: When debugging complex issues, always test if a simpler approach works first.

**Case Study - MCP Server TypeScript Diagnostics (August 2025)**:
- **Problem**: Complex MCP server architecture with custom init files, event-driven waits, and sophisticated LSP triggering failed to capture TypeScript diagnostics, despite hours of debugging
- **Solution**: Replaced with simple approach: direct user config loading, fixed 3-second waits, basic buffer setup
- **Result**: TypeScript diagnostics started working immediately
- **Lesson**: Sophisticated ≠ Better. The complex approach introduced subtle bugs that were hard to debug

### 2. Step-by-Step Debugging Methodology

When facing complex issues, follow this systematic approach:

1. **Reproduce the issue** - Create minimal test cases
2. **Create working baseline** - Find any approach that works, even if simple
3. **Compare approaches** - Identify exact differences between working vs broken
4. **Test theories individually** - Change one variable at a time
5. **Programmatic verification** - Write scripts to test hypotheses
6. **Environmental isolation** - Rule out timing, permissions, paths, etc.
7. **Adopt the working approach** - Don't be afraid to simplify

**Example Applied to MCP Diagnostics**:
1. Confirmed issue: TypeScript diagnostics missing in MCP server
2. Created manual headless test: TypeScript diagnostics worked
3. Compared: Manual vs MCP server environments  
4. Tested theories: headless_mode flag, timing, buffer creation
5. Built programmatic tests: Scripts that replicated both approaches
6. Isolated differences: Custom init files vs direct config loading
7. Adopted simple approach: Direct config, fixed timing, real file paths

### 3. Environmental Debugging

**Always verify assumptions about the environment**:
- Check if new code is actually running (add temporary debug prints)
- Verify working directories, file paths, permissions
- Test with minimal reproduction cases
- Use logging to trace execution flow
- Compare working vs non-working environments side-by-side

### 4. Documentation Through Discovery

When solving complex issues:
- Document the debugging process, not just the solution
- Capture failed approaches and why they failed  
- Note environmental factors that mattered
- Include reproduction steps for future debugging
- Update architecture docs with lessons learned

This prevents future developers (including future Claude instances) from repeating the same mistakes and provides debugging templates for similar issues.

## Coding Guidelines
- Always use single quotes instead of double quotes.

### Important Hints for Claude Code
- Hooks use wrapper scripts that handle base64 encoding before calling nvim-rpc
- The wrapper scripts are located in the `scripts/` directory of the plugin
- Base64 encoding is used to safely pass file paths and other data through shell commands
- The nvim-rpc.sh script uses Python with pynvim library for RPC communication (no nvr dependency)

```