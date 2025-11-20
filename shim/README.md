# FS Shim Prototype (Status: Paused)

This directory holds the in-progress macOS `DYLD_INSERT_LIBRARIES` shim we experimented with to block file writes (`write/pwrite/writev`, `truncate`, `rename`, `unlink`) and sync with a JSON-RPC sidecar before/after the change. The idea was to make the plugin agent-agnostic by interposing libc instead of relying on Claude/Codex hook systems.

## Why we paused this effort

| Issue | Impact |
| --- | --- |
| **Core utilities crash** | Injecting the shim into `/bin/ls`, `touch`, `git`, etc. causes immediate SIGKILL during locale/bootstrap. These binaries call cancellation-safe symbols (`close$NOCANCEL`, `write$NOCANCEL`) before the C runtime is fully initialised; our Rust/serde/HashMap/TLS guard isn’t async-signal-safe, so the kernel terminates the process. |
| **Brittle maintenance** | Every new macOS release reshuffles libc/dyld symbols. We’d need to chase `$UNIX2003/$NOCANCEL` variants, keep raw syscalls up to date, and guarantee no allocations/logging happen in those hooks. |
| **Operational friction** | Users must start a sidecar and export shim env vars. Forgetting to start the sidecar (or running any shell built-in) silently kills commands, which is unacceptable for Codex’s runtime. |

The shim does work for controlled processes (Python, editors, etc.) but not for general-purpose shells, which makes it unusable as an always-on guard inside Codex.

## Decision

We’re pausing further work on the shim and instead relying on higher-level observation:

1. **Claude Code** already exposes pre-/post-tool events via its hook system and OTEL exporter. We’ll keep consuming those.
2. **Codex** will be updated (or forked) so that `codex.tool_decision` OTEL events include the upcoming tool’s argv/env/cwd. The Neovim plugin can then snapshot baselines before the command runs, just like it does for Claude.

This approach matches our existing architecture, avoids OS-level interposing, and keeps Codex stable.

## Keeping the prototype

The Rust shim + Python sidecar remain here for reference (`shim/src/lib.rs`, `shim/fs_shim_sidecar.py`) in case we revisit a C-level implementation later, but they are **not** part of the supported workflow right now. Use at your own risk.  
