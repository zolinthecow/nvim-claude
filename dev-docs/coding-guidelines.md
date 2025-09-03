# Coding Guidelines

This project uses a strict facade pattern with clear module boundaries. Follow these rules for all code changes.

## Facades & Boundaries

- Facade per feature: Each feature directory exposes a single public facade in its `init.lua`.
  - `require('nvim-claude.events')`
  - `require('nvim-claude.inline_diff')`
  - `require('nvim-claude.utils')`
  - `require('nvim-claude.lsp_mcp')`
  - `require('nvim-claude.rpc')`
- Internals: Implementation lives in sibling modules within the same folder (e.g., `inline_diff/hunks.lua`, `navigation.lua`, `render.lua`).
- Imports: Cross‑feature code must import ONLY through the other feature’s facade. Never import internals from a different feature.
  - Good: `require('nvim-claude.events').pre_tool_use(...)`
  - Bad: `require('nvim-claude.events.session')`
  - Good: `require('nvim-claude.inline_diff').accept_all_files()`
  - Bad: `require('nvim-claude.inline_diff.hunks').accept_all_files()` (unless inside `inline_diff/*`).
- Intra‑feature: Modules within a feature (e.g., files under `inline_diff/`) may import each other’s internals as needed.

## Hooks & Shell

- Shell wrappers live under `claude-hooks/` and call the public events facade via `rpc/nvim-rpc.sh` → `events.adapter`.
- Never call internal Lua modules from shell directly; only the facade/endpoints in `events`.
- The Stop hook should output only `{ "decision": "approve" | "block" }` and include a stringified JSON `reason` when blocking.

## State Management

- Persisted state lives in `project-state.lua` and `inline_diff/persistence.lua` (baseline ref, edited files, etc.).
- Keep runtime‑only state minimal (e.g., inline diff visuals). Do not create alternate sources of truth that duplicate persisted data.

## Git & Files

- Use helpers in `utils/git.lua` where possible; shell commands must properly escape variables.
- Diff/baseline logic should live in `inline_diff/*` modules (`baseline.lua`, `diff.lua`, `hunks.lua`, `executor.lua`).

## Logging & Errors

- Use `logger.lua` for structured logging. Prefer returning `{ ok=false, reason=... }` or `{ status='error', info=... }` on failures.

## Conventions

- Avoid adding new globals; keep modules returning tables with functions.
- Keep façade modules thin: route, validate, and re‑export only.
- Keep changes focused; don’t fix unrelated issues in the same patch.

