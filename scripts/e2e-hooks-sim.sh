#!/usr/bin/env bash
set -euo pipefail

# Simulate Codex shell pre/post hooks end-to-end against a headless Neovim server.
# Notes:
# - Requires plenary (for minimal_init) and the plugin installed in runtimepath (this repo).
# - Requires the RPC venv installed by the plugin (run :lua require('nvim-claude').setup({}) once).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Starting headless Neovim server..."
NVIM_LOG="/tmp/nvim-claude-e2e-hooks.log"
rm -f "$NVIM_LOG" 2>/dev/null || true

# Start a headless server and ensure settings-updater writes the server file
nvim --headless -u tests/minimal_init.lua \
  -c 'lua vim.g.headless_mode = false' \
  -c 'lua require("nvim-claude").setup({})' \
  -c 'lua require("nvim-claude.settings-updater").refresh()' \
  -c 'sleep 1000m' >>"$NVIM_LOG" 2>&1 &
NVIM_PID=$!
sleep 0.4

cleanup() {
  kill $NVIM_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Preparing apply_patch JSON payload..."
PATCH='*** Begin Patch
*** Add File: E2E_TEST.txt
+hello from hooks sim
*** End Patch'

JSON=$(cat <<JSON
{
  "tool": "shell",
  "arguments": { "argv": ["apply_patch", "$PATCH"], "command": ["apply_patch", "$PATCH"] },
  "tool_input": { "command": "apply_patch $PATCH" },
  "cwd": "$ROOT_DIR",
  "git_root": "$ROOT_DIR",
  "success": true,
  "output": "Success. Updated the following files:\nA E2E_TEST.txt\n",
  "sub_id": "1",
  "call_id": "ci"
}
JSON
)

HOOKS="$ROOT_DIR/lua/nvim-claude/agent_provider/providers/codex/codex-hooks"

echo "Running shell-pre..."
bash "$HOOKS/shell-pre.sh" <<<"$JSON"

echo "Applying patch for real..."
apply_patch <<<"$PATCH" >/dev/null

echo "Running shell-post..."
bash "$HOOKS/shell-post.sh" <<<"$JSON"

echo "Querying Neovim state via RPC..."
RPC="$ROOT_DIR/rpc/nvim-rpc.sh"
if [[ ! -x "$RPC" ]]; then
  echo "RPC client not installed; run :ClaudeInstallMCP in Neovim first" >&2
  exit 1
fi

$RPC --remote-expr "luaeval('require(\\'nvim-claude.events\\').list_edited_files()')" || true

echo "Done. Logs: $NVIM_LOG"

