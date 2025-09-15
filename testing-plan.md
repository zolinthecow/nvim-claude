# Testing Plan

This plan establishes a minimal, fast, integration‑heavy test suite that exercises full flows end‑to‑end and catches regressions between PRs.

## Goals

- Fast iteration: under ~10s locally, <~20s in CI.
- High signal: focus on real user flows and cross‑module interactions.
- Stable: avoid external daemons or CLIs; rely on headless Neovim + git.
- Extensible: optional slower jobs can add full shell‑hook coverage or real agent CLIs later.

## Tiers

1) Fast E2E (recommended default)
- Drive the plugin through its public facades in a temp git repo.
- Simulate hook behavior via `events.adapter` b64 wrappers rather than shell processes.
- Validate diffs, baseline updates, and edited‑file tracking.

2) Unit/contract smoke (already present)
- Keep existing `tests/hunks_spec.lua` and `tests/events_spec.lua` as quick checks for planning logic and basic events.

3) Slow integration (optional/periodic)
- Exercise the shell hook scripts with JSON payloads (no real Codex/Claude needed).
- Optionally run real Codex/Claude CLIs when available (separate CI job).

## Proposed Fast E2E Tests

Add `tests/e2e_spec.lua` backed by a small `tests/helpers.lua`:

- Apply Patch Marking
  - Setup: create temp repo, write file, no baseline.
  - Simulate: `events.adapter.pre_tool_use_b64(abs)`, modify file, `events.adapter.post_tool_use_b64(abs)`.
  - Assert: baseline exists, file tracked in `events.list_edited_files()`, `inline_diff` shows hunks.

- Accept Current Hunk (execute)
  - Setup baseline, edit to create one hunk, mark edited.
  - Open buffer, ensure hunks exist.
  - Call `hunks.accept_current_hunk` → plan → `executor.execute(plan)`.
  - Assert: baseline contains new content; file untracked.

- Reject Current Hunk (execute)
  - Same setup, call `hunks.reject_current_hunk` → plan → execute.
  - Assert: file restored to baseline; file untracked.

- New File Flow
  - Create baseline, add a new file not in baseline, mark edited.
  - Case A: accept all → file added to baseline; untracked.
  - Case B: reject all → file deleted; untracked.

Optional next tests once green:
- Delete flow: `track_deleted_file_b64(abs)` then `rm`, verify deletion‑only diff and accept/reject.
- Persistence: save, reload modules, ensure state reloads and diffs still show.
- Minimal navigation/render checks: count hunks/extmarks/virt lines without snapshotting UI.

## Running Current Tests

- All tests: `./scripts/run_tests.sh`
- Events: `./scripts/run_events_tests.sh`
- Hunks: `./scripts/run_hunks_tests.sh`

## Headless Agent E2E in CI

There are two viable CI approaches to exercise the full hook path from a synthetic 'apply_patch' payload into Neovim state.

### A) Simulated Hooks (recommended default)

No Codex/Claude binaries required. We invoke our shell hooks directly with a JSON payload that mirrors Codex, and let the hooks call `rpc/nvim-rpc.sh` into a headless Neovim server.

Steps (CI script sketch):

1. Start a headless Neovim server with this plugin enabled and ensure it writes the server file.

```bash
repo_root=$(pwd)
proj_root="$repo_root"  # or a temp git repo you init
nvim --headless -u tests/minimal_init.lua \
  -c 'lua vim.g.headless_mode = false' \
  -c 'lua require("nvim-claude").setup({})' \
  -c 'lua require("nvim-claude.settings-updater").refresh()' \
  -c 'sleep 500m' &
NVIM_PID=$!
```

2. Prepare an `apply_patch` JSON like the Codex shell tool would send:

```bash
PATCH='*** Begin Patch
*** Update File: LICENSE
@@
-line one
+line one (ci)
*** End Patch'

JSON=$(cat <<JSON
{
  "tool": "shell",
  "arguments": { "argv": ["apply_patch", "$PATCH"], "command": ["apply_patch", "$PATCH"] },
  "tool_input": { "command": "apply_patch $PATCH" },
  "cwd": "$proj_root",
  "git_root": "$proj_root",
  "success": true,
  "output": "Success. Updated the following files:\nM LICENSE\n",
  "sub_id": "1",
  "call_id": "ci"
}
JSON
)
```

3. Run pre/post shell hooks with the JSON payload (they will call `rpc/nvim-rpc.sh`):

```bash
HOOKS=lua/nvim-claude/agent_provider/providers/codex/codex-hooks
bash "$HOOKS/shell-pre.sh" <<<"$JSON"
# apply the patch for real (so file content matches)
apply_patch <<<"$PATCH"
bash "$HOOKS/shell-post.sh" <<<"$JSON"
```

4. Inspect Neovim state via RPC:

```bash
RPC=rpc/nvim-rpc.sh
FILES=$($RPC --remote-expr "luaeval('require(\\'nvim-claude.events\\').list_edited_files()')")
echo "$FILES"
```

5. Cleanup: `kill $NVIM_PID`.

Notes:
- Ensure the RPC venv is installed once in CI by calling `:lua require('nvim-claude.rpc').ensure_installed()` or by running the plugin normally which installs it on demand.
- The hooks derive the project hash from `cwd`/`git_root`; the `settings-updater` writes the server file to `$XDG_RUNTIME_DIR` or `/tmp` so `rpc/nvim-rpc.py` can find it.

### B) Real Codex/Claude CLIs (optional)

If the CI runner has Codex or Claude Code installed, you can run a real end‑to‑end edit:

1. Install provider hooks via the plugin (this writes config to `~/.codex/config.toml` or Claude settings via `settings-updater`).
2. Start the Neovim headless server and ensure the server file is written (set `vim.g.headless_mode = false`).
3. Invoke the CLI with a simple instruction that yields a one‑line change (e.g., 'append a line to LICENSE') and let the hooks capture edits.
4. Inspect Neovim state via RPC as above.

Because CLIs add weight and external dependencies, keep this as an optional separate job.

## Why Simulated Hooks in CI

- Stability: avoids external CLIs and permissions prompts.
- Fidelity: exercises our parsing, path resolution, and adapter code, which is where most regressions occur.
- Speed: single process per step, no network calls.

## Next Steps

- Add `tests/helpers.lua` and `tests/e2e_spec.lua` implementing the four core E2E tests above.
- Add a `scripts/e2e-hooks-sim.sh` to run the simulated‑hooks flow end‑to‑end (used by CI job).
- Optional: add a second CI job for real Codex/Claude when runners provide those binaries.

