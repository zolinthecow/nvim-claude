# ACP Integration Design

## Shim-Based ACP Environment (Preferred Approach)

We want to preserve the stock CLI UX (users run `codex`, `claude`, etc. inside the tmux pane) while still getting structured file events. Native ACP adapters replace the CLI UI, so instead we’ll build a lightweight “shim” process that:

- Launches the requested agent binary unchanged (Codex, Claude, future providers) inside the tmux pane.
- Intercepts filesystem syscalls (`open`, `read`, `write`, `unlink`, `rename`, etc.) plus terminal launches via LD_PRELOAD (Linux/macOS) or dynamic library injection (Windows) so every file operation flows through the shim before touching disk.
- Pipes those intercepted operations to Neovim over a simple RPC (ACP-inspired, possibly the same JSON-RPC framing) so we can call `events.pre_tool_use/post_tool_use/track_deleted_file` with exact paths and contents.
- Forwards terminal commands untouched so the CLI continues rendering normally; the shim just mirrors stdout/stderr to the RPC channel if we need to record them.

Benefits:

- Works with any agent process (no need for provider-specific integrations once interception is in place).
- Resistant to upstream changes: regardless of how Codex implements `apply_patch` internally, every write hits our shim first.
- Keeps user workflow identical (same CLI, no new UI). The tmux pane shows the real agent exactly as before.

Implementation outline:

1. **Shim binary** (Rust/C) that injects into the agent process and exports replacements for the specific libc calls we care about (macOS-only in the first iteration via `DYLD_INSERT_LIBRARIES`). Target intercept list:
   - File opens: `open`, `open64`, `openat`, `openat64`, `creat` (needed to map file descriptors → paths so later writes/deletes know which file they touch).  
   - Writes: `write`, `writev`, `pwrite`, `pwrite64`, `pwritev`, `ftruncate`, `truncate`, `fsync` (lets us snapshot contents before and after overwrites/appends).  
   - Closes: `close` (final hook to emit `post_tool_use` once all writes on a fd complete).  
   - Deletes: `unlink`, `unlinkat`, `remove`, `rmdir`.  
   - Moves: `rename`, `renameat`, `renameat2`.  
   - Links/new files: `link`, `linkat`, `symlink`, `symlinkat` (treat as copies so baseline knows about new paths).  
   - Command exec: `execve`, `posix_spawn` (optional, used if we need to mirror shell commands into Neovim).  
   On macOS/Linux we can inject via `DYLD_INSERT_LIBRARIES` / `LD_PRELOAD` and forward to the real libc after logging.  
2. **RPC bridge**: shim connects back to Neovim via a Unix socket (or our embedded OTEL listener port) and emits ACP-shaped JSON-RPC messages so the stream stays compatible with the spec. For the first iteration we only mirror filesystem events; prompts/turn lifecycle continue to flow through the existing provider integrations (Claude hooks, Codex OTEL) to keep scope manageable. Emitted messages:
   - `fs/write_text_file { path, content }` whenever the CLI writes or truncates a file.  
   - `fs/remove { path }` on deletes.  
   - `fs/rename { oldPath, newPath }` on moves.  
   - `fs/read_text_file { path }` only when the CLI reads context and we need to proxy it (likely no-op since the CLI still reads directly).  
3. **Neovim handler**: new Lua module that listens for the ACP-style RPC requests and maps each one onto our existing event façade:  
   - `fs/write_text_file` → `events.pre_tool_use(abs_path)` (before writing), write `content` to disk, then `events.post_tool_use(abs_path)`.  
   - `fs/remove` → `events.track_deleted_file(abs_path)` before deleting; if deletion fails emit `events.untrack_failed_deletion(abs_path)`.  
   - `fs/rename` → treat as `track_deleted_file(old)` + `pre_tool_use(new)` + write + `post_tool_use(new)` so baseline captures both sides.  
   - `fs/read_text_file` → simple passthrough (`vim.fn.readfile`) with no baseline updates.  
4. **Provider changes**: Claude/Codex provider setup just prepends our shim env vars (`LD_PRELOAD=/path/to/shim.so`) before launching the CLI in tmux. No more hook installers or OTEL listeners.  

This shim gives us ACP-like guarantees (exact pre/post snapshots) while letting users keep their familiar CLI. The remainder of this doc focuses on the ACP-style message flow between the shim and Neovim, so the same design works whether the events originate from a true ACP adapter or our syscall interceptor.

## Background

- Today the Claude provider installs hook scripts that call `events.pre_tool_use/post_tool_use` via `nvim-rpc`, and the Codex provider is moving to OTEL log parsing.  
- Both approaches rely on provider-specific plumbing to discover file paths. They break whenever event payloads change and require bespoke diagnostics.  
- The Agent Client Protocol (ACP) already defines structured JSON-RPC messages for editor ↔ agent communication (`fs.read_text_file`, `fs.write_text_file`, `terminal/execute`, etc.).  
- Zed maintains ready-made ACP adapters for Codex (`zed-industries/codex-acp`) and Claude Code (`zed-industries/claude-code-acp`). They launch the stock CLI and proxy all filesystem/tool requests through ACP.

## Goals

1. Consume ACP events directly so nvim-claude no longer depends on hook scripts or OTEL diffs.  
2. Reuse the existing baseline / inline-diff engine (no changes to `lua/nvim-claude/events/*` or `inline_diff/*`).  
3. Support both Codex and Claude adapters with a shared ACP client runtime.  
4. Preserve current UX (`<leader>cc`, background agents, targeted panes).  

## Non-Goals

- Changing the baseline semantics (`events.pre_tool_use` / `.post_tool_use`).  
- Replacing the tmux chat transport; panes still run the agent process (now via ACP wrappers).  
- Implementing the full ACP spec (we only need the subset required by the adapters: initialization, prompts, file ops, terminal exec, optional diagnostics).  

## High-Level Architecture

```
Neovim (Lua) ──spawn────┐
                        │ stdio (JSON-RPC / ACP)
ACP client runtime <────┤────> codex-acp (or claude-code-acp)
                        │
                        └─ tmux pane (existing chat UI) runs the same binary
```

### Components

| Component | Responsibilities |
| --- | --- |
| `acp/client.lua` (new) | JSON-RPC transport, request/response correlation, reconnection. |
| `acp/session.lua` (new) | Implements ACP client APIs we care about: send `initialize`, `new_session`, `prompt`; handle incoming requests (`fs.*`, `terminal.*`). |
| `agent_provider/providers/acp_common.lua` (new) | Shared logic for both Codex/Claude providers (spawn command, tmux integration, wiring to `acp/client.lua`). |
| `agent_provider/providers/{codex,claude}/init.lua` (new impl) | Thin wrappers that configure spawn command (`codex-acp`, `claude-code-acp`), env vars, chat helpers. |

## ACP APIs & nvim-claude Mapping

### Connection + Session

1. **`initialize`** (Client → Agent)  
   - Send once per process startup. Include:
     - `protocolVersion = "1.0.0"` (or latest).  
     - `clientCapabilities.fs = { readTextFile = true, writeTextFile = true }` so the agent routes all edits through us.  
     - `clientCapabilities.terminal.execute = true` if we want the agent to keep running commands in our tmux pane (optional).  
   - Save `agentCapabilities` from the response for diagnostics (e.g., `agentCapabilities.promptCapabilities`).  

2. **`new_session`** / **`prompt`**  
   - Called by our chat UI when the user opens `<leader>cc`.  
   - The chat pane keeps running the adapter binary for human interaction; in parallel the Neovim-side ACP client opens its own session (headless) used solely for file ops + tool approvals.  
   - We mirror the text the user typed in the pane to ACP via `prompt` when necessary (future enhancement; out of scope for initial baseline).  

### File System (core of baseline integration)

Incoming ACP requests from the adapter and their mapping:

| ACP Request | Action in nvim-claude |
| --- | --- |
| `fs/read_text_file` | Read file content from disk using `vim.fn.readfile`. Needed when agent wants context (no baseline changes). |
| `fs/write_text_file` | **Primary hook:** Agents send the entire file contents (not a patch) under `params.content`, see ACP schema `WriteTextFileRequest`.  
  1. Resolve absolute path (ACP paths are absolute already, but normalize via `vim.fn.fnamemodify`).  
  2. Call `events.pre_tool_use(abs_path)` so the baseline captures the current on-disk version.  
  3. Overwrite the file with `params.content` verbatim (`vim.fn.writefile(vim.split(content, '\n'))`).  
  4. Call `events.post_tool_use(abs_path)` to mark the file edited and refresh inline diffs.  
  5. Return `{}` on success or propagate errors (permission denied, etc.). |
| `fs/remove` / `fs/remove_dir` |  
  - Call `events.track_deleted_file(abs_path)` before deletion.  
  - Delete file.  
  - Respond success; on failure call `events.untrack_failed_deletion(abs_path)`. |
| `fs/read_dir` (if invoked) | Pass-through to filesystem; no diffs needed. |

Because the adapter routes *every* edit through `fs.write_text_file`, we no longer depend on tool-specific metadata—the baseline gets the pre-tool snapshot just before we overwrite the file.

### Terminal / Exec

- Advertise `clientCapabilities.terminal = { execute = true }` so the adapters route shell commands through us (matches Claude Code/Codex defaults).  
- Implementation plan: reuse the existing tmux pane per provider and forward ACP terminal traffic to it. We’ll add dedicated helpers in `lua/nvim-claude/utils/tmux.lua`:
  - `tmux.start_terminal_session(pane_id, cmd, env)` → runs cmd in pane, returns a terminal handle (pane_id + job id if we tail output).
  - `tmux.send_terminal_input(handle, data)` → send raw data (used for `terminal/write`).
  - `tmux.resize_terminal(handle, rows, cols)` → wraps `tmux.resize_pane`.
  Each ACP terminalId maps 1:1 to a tmux handle; `terminal/execute` creates a handle, subsequent ACP `terminal.write`/`terminal.resize` notifications call the helper, and `terminal/on_exit` responds when the command finishes.
- For headless runs (no pane), fall back to spawning a hidden terminal buffer using `vim.fn.termopen` so the agent still receives output/exit codes.  
- We must also handle `terminal/write` and `terminal/resize` notifications to keep the ACP stream happy; those map to `tmux.send_text` and `tmux.resize_pane`.

### User Prompts & Checkpoints

- The adapters surface user prompts as part of `prompt` / `session` updates (ACP `SessionNotification` with `toolCalls`).  
- Whenever the user submits text via `<leader>cc`, we already know the prompt string; call `events.user_prompt_submit(prompt)` just like our OTEL hook.  
- ACP also emits `RequestPermission` messages (e.g., tool approval). We can auto-approve or surface via Neovim in the future.

## Provider Integration Plan

1. **Shared ACP runtime** (`lua/nvim-claude/acp/*.lua`):
   - Transport: `uv.spawn` adapter binary, connect pipes, encode/decode JSON-RPC.  
   - Request router: maintain `pending[id] = callback`, support notifications.  
   - Handlers: `fs.write_text_file`, `fs.remove`, `fs.read_text_file`.

2. **Codex provider rewrite** (`providers/codex/init.lua`, etc.):
   - Replace OTEL/hook installers with ACP config (`codex-acp` path, env).  
   - Chat helper still opens tmux pane running `codex-acp`.  
   - `setup` starts the ACP client runtime (headless).  
   - Remove `otel_listener.lua`; all baseline updates now come from `fs.write_text_file`.

3. **Claude provider rewrite** (same pattern using `claude-code-acp`).  

4. **Configuration surface**:
   - Extend `require('nvim-claude').setup` to accept `provider = 'codex_acp'` or `'claude_acp'`.  
   - Options: adapter command, extra env vars, log level, reconnection policy.

5. **Testing**:
   - Create fake ACP agent for unit tests (Lua module that sends synthetic `fs.write_text_file`).  
   - Add regression tests ensuring `events.pre_tool_use` receives the correct path order (pre → write → post).  
   - Manual validation: run `codex-acp`, edit files, ensure inline diffs appear without OTEL/hook config.

## Open Questions

1. **Single vs dual session**: Can we reuse the tmux-pane session for the headless file channel, or do the adapters require separate sessions per connection? (Need to inspect adapter docs; likely per-connection.)  
2. **Command execution**: Do we need `terminal.execute` for parity with existing behavior? If not, how does the agent run commands (does adapter fall back to local shell)?  
3. **Permissions UI**: ACP supports interactive permission prompts. Should Neovim expose these via floating windows, or auto-approve everything as today’s CLI does?  
4. **Multiple providers**: Should we build a single ACP provider that can talk to any adapter (Codex, Claude, future MCP agents) by configuring the spawn command?  

## Next Steps

1. Prototype the shim’s JSON-RPC output using `scripts/shim-test-server.py` (`./scripts/shim-test-server.py --unix /tmp/nvim-claude-shim-test.sock`) and confirm Codex/Claude emits the expected `fs/*` payloads.  
2. Build the Lua listener (`acp/shim_client.lua`) that consumes those payloads and calls `events.*`.  
3. Replace the Codex provider’s OTEL path with the shim injection path; ensure inline diffs update when running the CLI with `DYLD_INSERT_LIBRARIES`.  
4. Port the Claude provider and update docs/installer instructions (`README`, `AGENTS`).  
