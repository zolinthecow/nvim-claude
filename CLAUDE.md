# Agent guide

This file provides guidance to coding agents such as Claude Code (claude.ai/code) or Codex when working with code in this repository.

## Development Commands

### Testing Changes
```bash
# Test plugin in Neovim (from parent directory)
nvim
# In Neovim:
:source lua/nvim-claude/init.lua     " reload plugin
:ClaudeDebugLogs                     " view paths and open logs
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
The inline diff system uses a baseline git commit capturing pre-edit state:

- Baseline creation: `events.adapter.pre_tool_use_b64()` triggers commit creation via `inline_diff/baseline.lua`
- File tracking: `events.core.post_tool_use()` marks files in `project-state.lua` under `claude_edited_files`
- Diff display: `inline_diff/init.lua` facade displays diffs by comparing buffer content vs baseline commit
- Persistence: `inline_diff/persistence.lua` and `project-state.lua` store baseline ref and edited files
- Baseline ref: stored as `refs/nvim-claude/baseline`

Flow:
1. PreToolUse (Edit/Write/MultiEdit) → create/update baseline commit
2. PostToolUse(file) → record file as edited, refresh inline diff
3. Accept hunk → `inline_diff/hunks.lua` patches baseline commit tree
4. Reject hunk → reverse patch to working file

#### 2. Module Map (updated)
```
init.lua (entry point)
├── events/ (public facade + internals)
│   ├── init.lua (facade: pre/post hooks, install, session helpers)
│   ├── core.lua (pre/post/user_prompt handlers)
│   ├── installer.lua (.claude hook installer)
│   ├── adapter.lua (rpc-facing helpers)
│   └── autocmds.lua (editor event wiring)
├── inline_diff/
│   ├── init.lua (facade: show/refresh, delegates)
│   ├── baseline.lua (baseline commit ref + updates)
│   ├── hunks.lua (accept/reject logic)
│   ├── navigation.lua (list/next/prev, deleted view)
│   ├── diff.lua (compute hunks)
│   ├── render.lua (virt text/lines)
│   ├── executor.lua (apply actions)
│   └── persistence.lua (project state)
├── utils/
│   ├── init.lua (facade)
│   ├── git.lua (git helpers)
│   └── tmux.lua (tmux helpers)
├── lsp_mcp/ (MCP tools + installer)
├── rpc/ (nvim-rpc.sh, helpers)
├── background_agent/ (agents + registry)
├── checkpoint/ (checkpoints)
├── agent_provider/
│   └── providers/
│       ├── claude/
│       │   ├── init.lua (provider façade)
│       │   ├── hooks.lua (installer)
│       │   ├── chat.lua (pane send)
│       │   ├── background.lua (agent pane launch)
│       │   ├── config.lua (spawn, pane title)
│       │   └── claude-hooks/ (shell wrappers: pre/post/bash/stop/user-prompt)
│       └── codex/
│           ├── init.lua (provider façade)
│           ├── hooks.lua (installer: writes `[otel]` + `[mcp_servers.nvim-lsp]` to ~/.codex/config.toml)
│           ├── chat.lua (pane send)
│           ├── background.lua (agent pane launch; CODEX_HOME cloned + hooks stripped; --full-auto with task)
│           ├── config.lua (spawn, pane title, OTEL port/env)
│           └── otel_listener.lua (embedded OTLP/HTTP server that mirrors telemetry events into events.core)
├── logger.lua, project-state.lua, mappings.lua, statusline.lua
```

#### 3. State Management
The plugin maintains several types of state:

- **Baseline Reference**: `persistence.get_baseline_ref()` - SHA of the baseline commit
- **Tracked Files**: `hooks.claude_edited_files` - Map of relative paths  
- **Active Diffs**: `inline-diff.active_diffs[bufnr]` - Current diff data per buffer
- **Persistence Locations** (all stored globally):
  - Inline diff state: `~/.local/share/nvim/nvim-claude/projects/<path-hash>/inline-diff-state.json`
  - Agent registry: `~/.local/share/nvim/nvim-claude/projects/<path-hash>/agent-registry.json`
  - Debug logs: `~/.local/share/nvim/nvim-claude/logs/<path-hash>/debug.log`
  - Server file: `/tmp/nvim-claude-<path-hash>-server` (or `$XDG_RUNTIME_DIR`)
- **Checkpoint Data**: Stored as git commits with refs `refs/nvim-claude/checkpoints/*`

State cleanup happens when:
- All hunks in a file are accepted/rejected → File removed from tracking
- All tracked files processed → Baseline cleared, persistence deleted
- Project deleted → Use `:ClaudeCleanupProjects` to remove orphaned state

#### 4. Hook System Integration
Claude Code hooks are installed via `.claude/settings.local.json`.

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

Wrappers call `rpc/nvim-rpc.sh` (Python-based RPC client using pynvim) to communicate with the running Neovim instance via the public events facade.

Codex integration no longer installs shell hooks. Instead, `hooks.lua` writes:

```toml
[otel]
environment = "dev"
log_user_prompt = false
exporter = { otlp-http = { endpoint = "http://127.0.0.1:4318/v1/logs", protocol = "json" } }
```

The Codex CLI streams `codex.tool_decision`, `codex.tool_result`, and `codex.user_prompt` events over OTLP/HTTP. `otel_listener.lua` runs a lightweight HTTP server inside Neovim, decodes the OTLP JSON payloads, and calls `events.core` APIs to:

- ensure baselines are created before the first tool runs (on `codex.tool_decision`)
- diff git status snapshots per tool call to identify edited/deleted files (on `codex.tool_result`)
- propagate user prompts so checkpoints stay in sync (on `codex.user_prompt`)

`config.lua` exposes `otel_log_user_prompt` (default `true`) so checkpoint previews include the actual prompt. Set it to `false` to keep Codex telemetry redacted (`[REDACTED]`), in which case checkpoints fall back to the placeholder `"Codex prompt (redacted)"`.

### Codex Setup (submodule)
This plugin vendors the Codex fork as a submodule for compatibility with the CLI APIs that expose telemetry metadata.

```bash
git submodule update --init --recursive lua/nvim-claude/agent_provider/providers/codex/codex
```

Build/install the Codex CLI from the submodule (or ensure your PATH points to it), then select the provider and install hooks:

```vim
lua << EOF
require('nvim-claude').setup({ provider = { name = 'codex' } })
EOF
:ClaudeInstallHooks
```

`:ClaudeInstallHooks` now writes a managed `[otel]` block (pointing at the embedded listener) plus `[mcp_servers.nvim-lsp]` for diagnostics.

### Key Implementation Details

#### Commit References
- Baselines are stored as git commits with SHA hashes (e.g., `8b0902ed0df...`) under `refs/nvim-claude/baseline`
- Creation/update handled by `inline_diff/baseline.lua`

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
1. Define function in the appropriate module (e.g., `inline_diff/hunks.lua` or `events/core.lua`)
2. Add command in `commands.lua` using `vim.api.nvim_create_user_command`
3. Add keymap in `mappings.lua` or `setup_inline_keymaps()`
4. Update README.md with new command/keymap

#### Debugging State Issues
1. Check persistence file: `cat ~/.local/share/nvim/nvim-claude/projects/<path-hash>/inline-diff-state.json | jq`
2. Check baseline commit exists: `git show refs/nvim-claude/baseline`
3. Verify tracked files: `:lua print(vim.inspect(require('nvim-claude.events').list_edited_files()))`
4. Check baseline ref: `:lua print(require('nvim-claude.inline_diff').get_baseline_ref())`
5. View all nvim-claude refs: `git for-each-ref refs/nvim-claude/`

### Critical Functions

#### `inline_diff.hunks.accept_current_hunk(bufnr)`
- Updates git baseline commit to include accepted changes
- Removes file from tracking if no diffs remain
- Saves persistence state

#### `inline_diff.hunks.reject_current_hunk(bufnr)`
- Generates patch for the hunk
- Applies patch in reverse using `git apply --reverse`
- Recalculates diff against unchanged baseline

#### `inline_diff.init.show_inline_diff(bufnr, old, new)`
- Accepts explicit old/new content and renders hunks for the buffer

#### `inline_diff.persistence.save_state(state)`
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
- Baseline Commits: Snapshot of pre-edit state stored under `refs/nvim-claude/baseline`
- Baseline Reference: use `require('nvim-claude.inline_diff').get_baseline_ref()` / `.set_baseline_ref()`
- Claude Edited Files: tracked in project-state under `claude_edited_files` (use `require('nvim-claude.events').list_edited_files()`)
- Checkpoint System: Separate from baselines, allows saving/restoring work states

#### 3. Common Gotchas
- **New Files**: Files that don't exist in the baseline commit will cause git errors. Always check for `fatal:` or `error:` in git command outputs.
- **Path Handling**: Always use `vim.pesc()` when escaping paths for pattern matching.
- **Persistence**: The plugin uses global storage in `~/.local/share/nvim/nvim-claude/`.
- **Error Handling**: `utils.exec()` returns output even on error - check both return values and content for error messages.
- **Baseline vs Checkpoints**: Baselines track Claude's edits; checkpoints save user work states.

#### 4. Essential Files to Read First
1. `lua/nvim-claude/events/` - Facade + core hook logic (`init.lua`, `core.lua`, `installer.lua`, `adapter.lua`)
2. `lua/nvim-claude/inline_diff/` - Facade + internals (`init.lua`, `hunks.lua`, `navigation.lua`, `baseline.lua`, `render.lua`)
3. `lua/nvim-claude/project-state.lua` - Global state storage

#### 5. Testing Workflow
```bash
# 1. Make changes to the plugin
# 2. In Neovim, reload the plugin:
:source lua/nvim-claude/init.lua

# 3. Test your changes:
:ClaudeDebugInlineDiff  # Shows current state
<leader>if              # Manual refresh diff
```

### Testing Strategy & Coverage

- Scope: We prioritize fast, integration‑heavy tests that validate end‑to‑end flows, with a small unit suite for inline diff contracts.
- Fast E2E (default): `./scripts/run_e2e_tests.sh`
  - Covers events façade pre/post flows, baseline creation/updates, inline diff rendering, and executor accept/reject, including new‑file paths.
  - Tests live in `tests/e2e_spec.lua` and use temp git repos; no external CLIs or hooks.
- Unit (inline diff): `./scripts/run_tests.sh` also runs `tests/inline_diff_unit_spec.lua`
  - Validates hunks plan generation and executor action contracts via the public facades.
- Optional OTEL simulation script (planned replacement for the old `scripts/e2e-hooks-sim.sh`)
  - Starts a headless Neovim server, runs the real Codex shell pre/post hooks with a JSON payload, applies a patch, then inspects Neovim state via RPC.
  - Useful as a separate CI job; not required for fast iteration.

Interfaces under E2E contract
- `lua/nvim-claude/events/init.lua` façade: pre_tool_use, post_tool_use, deletion tracking, and session helpers.
- `lua/nvim-claude/inline_diff/init.lua` façade: refresh/show, accept/reject current/all, and diff state helpers.

Guideline for contributors and agents
- E2E tests exercise the public facades. Any change to these façade APIs or their semantics must update the E2E tests accordingly.
- Internal refactors are welcome as long as the façade contracts remain stable and E2E tests continue to pass.


#### 6. Debugging Commands
```vim
" Check tracked files
:lua print(vim.inspect(require('nvim-claude.events').list_edited_files()))

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
1. Hook Layer: shell wrappers in `claude-hooks/*` call the events facade
2. Events Layer: `events/core.lua` updates state and orchestrates baseline/refresh
3. Diff Layer: `inline_diff/*` computes hunks and renders visuals
4. Persistence Layer: `inline_diff/persistence.lua` + `project-state.lua`
5. Checkpoint Layer: `checkpoint/*` manages save points
6. Agent Layer: `background_agent/*` manages worktrees
7. MCP Layer: `lsp_mcp/*` provides diagnostics via headless Neovim

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
- Diff not showing: ensure a baseline exists; save the file or call `refresh_inline_diff()`
- Persistence issues: check inline-diff JSON and `refs/nvim-claude/baseline`
- New file issues: handle absent baseline content gracefully
- LSP diagnostics not working:
  - Verify MCP venv: `~/.local/share/nvim/nvim-claude/mcp-env/`
  - Check pynvim installed in venv
  - Use `:ClaudeDebugLogs` to find and open logs
- Stop hook: logs are unified in the same per-project `debug.log` (see `:ClaudeDebugLogs`)

### Hook Debugging Methodology

When hooks aren't working as expected, follow this step-by-step debugging process:

#### 1. Check the Hook Logs
```bash
# Find project-specific debug log path in Neovim
:ClaudeDebugLogs

# Or tail the log directly (replace <hash>)
tail -50 ~/.local/share/nvim/nvim-claude/logs/<hash>/debug.log

# Search for specific file or command
tail -100 ~/.local/share/nvim/nvim-claude/logs/<hash>/debug.log | grep -A5 -B5 "filename"
```

#### 2. Test nvim-rpc Commands Manually
Before debugging complex hook flows, test individual components:

```bash
# Test basic nvim-rpc connectivity
./rpc/nvim-rpc.sh --remote-expr "1+1"

# Test luaeval syntax
./rpc/nvim-rpc.sh --remote-expr 'luaeval("1+1")'

# Test requiring a module
./rpc/nvim-rpc.sh --remote-expr 'luaeval("require(\"nvim-claude.events\")")'

# Test specific functions (with TARGET_FILE for correct project)
TARGET_FILE="/path/to/file" ./rpc/nvim-rpc.sh --remote-expr 'luaeval("require(\"nvim-claude.events.adapter\").post_tool_use_b64()")'
```

#### 3. Debug Hook Command Construction
If hooks are failing, manually construct and test the exact command:

```bash
# Example: Test what the bash hook would send
ABS_PATH="/path/to/file"
ABS_PATH_ESCAPED=$(echo "$ABS_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
echo "Escaped path: $ABS_PATH_ESCAPED"
TARGET_FILE="$ABS_PATH" ./rpc/nvim-rpc.sh --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64()\")"
```

#### 4. Check Module Loading
If functions appear to not exist:

```bash
# Force reload module and test
./rpc/nvim-rpc.sh -c "lua package.loaded['nvim-claude.events'] = nil; require('nvim-claude.events')"

# Check if function exists
./rpc/nvim-rpc.sh --remote-expr "luaeval(\"type(require('nvim-claude.events').pre_tool_use)\")"
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
./rpc/nvim-rpc.sh --remote-expr "luaeval(\"vim.inspect(require('nvim-claude.events').list_edited_files())\")"
./rpc/nvim-rpc.sh --remote-expr "luaeval(\"require('nvim-claude.inline_diff').get_baseline_ref()\")"
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
# 4. Check logs immediately (replace <hash>)
tail -20 ~/.local/share/nvim/nvim-claude/logs/<hash>/debug.log

# 5. Test the specific operation (edit/delete)
# 6. Verify state changes
:lua print(vim.inspect(require('nvim-claude.events').list_edited_files()))
```

#### 8. Codex Telemetry Debugging
- Verify `~/.codex/config.toml` contains the `[otel]` block with `exporter = { otlp-http = { endpoint = "http://127.0.0.1:<port>/v1/logs", protocol = "json" } }`.
- Ensure the local listener is running: `lsof -i :<port>` should show `nvim` bound to `127.0.0.1`.
- Use `tail -f ~/.local/share/nvim/nvim-claude/logs/<hash>/debug.log | grep codex_otel` to confirm events are processed.
- If Codex sends telemetry but files are not tracked, run `git status --porcelain` manually before/after a command to confirm the snapshot diff matches expectations.
- To restart the listener without restarting Neovim: `:lua require('nvim-claude.agent_provider.providers.codex.otel_listener').ensure(require('nvim-claude.agent_provider.providers.codex.config').otel_port)`

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

### Lua Code Style
- Requires at Top: Put `require(...)` at the top of the file by default. This makes dependencies easy to audit and fails fast if something is missing.
- Exceptions for In‑Function Requires: Use `require` inside functions only when it:
  - Breaks a circular dependency on load order
  - Defers a heavy/optional dependency to a rare path (keeps startup fast)
  - Avoids side effects that must not run at module load time
  - Depends on runtime‑specific context (e.g., UI‑only code vs headless)
- Performance Note: `require` is cached via `package.loaded`, so calling it inside functions is cheap but still avoid doing so in hot loops.

### Facade Pattern (Imports and Exports)
- Import via Facades: Cross‑feature imports must go through the public `init.lua` facade of that feature.
  - Good: `require('nvim-claude.events')`, `require('nvim-claude.inline_diff')`, `require('nvim-claude.utils')`
  - Bad: `require('nvim-claude.events.session')` from outside the events feature
- Explicit Exports: Each facade should export a minimal, explicit API. Do not return raw internal tables.
  - Example: In providers, export `chat = { ensure_pane = fn, send_text = fn }` instead of `chat = internal_module`.
- Internal Structure: Features may have internal modules (`core.lua`, `hooks.lua`, etc.) that are not imported cross‑feature.

### Provider Modules
- Structure provider implementations under `agent_provider/providers/<name>/` with submodules like `hooks.lua`, `chat.lua`, `background.lua`, and an `init.lua` that composes explicit exports.
- Keep provider APIs consistent across implementations so callers depend only on the façade (`agent_provider`).

### Important Hints
- Hooks use wrapper scripts that handle base64 encoding before calling nvim-rpc
- Wrapper scripts live in `claude-hooks/` and the RPC client is `rpc/nvim-rpc.sh`
- RPC uses Python with pynvim for communication (no nvr dependency)
- Use only the events facade from shell hooks: `require('nvim-claude.events')` via `events.adapter`
 
### Import Rules (Facade Pattern)
- Each feature exposes a facade in `init.lua`. Keep facades free of implementation details.
- Cross‑feature code must import via facades only:
  - Good: `require('nvim-claude.events')`, `require('nvim-claude.inline_diff')`, `require('nvim-claude.utils')`
  - Bad: `require('nvim-claude.events.session')` or `require('nvim-claude.inline_diff.hunks')` from another feature
- Internal modules may import other internals within the same feature.
