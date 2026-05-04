#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nvim-claude-opencode.XXXXXX")"
REPO="$TMP_ROOT/repo"
RUNTIME_DIR="$TMP_ROOT/runtime"
CONFIG_DIR="$TMP_ROOT/config"
STATE_DIR="$TMP_ROOT/state"
SOCKET="$TMP_ROOT/nvim.sock"
NVIM_LOG="$TMP_ROOT/nvim.log"

cleanup() {
  if [ -n "${NVIM_PID:-}" ] && kill -0 "$NVIM_PID" >/dev/null 2>&1; then
    kill "$NVIM_PID" >/dev/null 2>&1 || true
    wait "$NVIM_PID" >/dev/null 2>&1 || true
  fi
  if [ "${NVIM_CLAUDE_KEEP_TMP:-}" != "1" ]; then
    rm -rf "$TMP_ROOT"
  else
    printf 'Kept temp dir: %s\n' "$TMP_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$REPO" "$RUNTIME_DIR" "$CONFIG_DIR" "$STATE_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_CONFIG_HOME="$CONFIG_DIR"

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
printf 'alpha old\n' > "$REPO/alpha.txt"
printf 'beta old\n' > "$REPO/beta.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m initial

repo_b64="$(printf '%s' "$REPO" | base64 | tr -d '\n')"
state_b64="$(printf '%s' "$STATE_DIR" | base64 | tr -d '\n')"
setup_lua="local root = vim.base64.decode('$repo_b64'); local state_dir = vim.base64.decode('$state_b64'); vim.fn.chdir(root); local ps = require('nvim-claude.project-state'); ps.get_global_state_dir = function() vim.fn.mkdir(state_dir, 'p'); return state_dir end; ps.get_state_file = function() return state_dir .. '/state.json' end; local logger = require('nvim-claude.logger'); logger.get_log_file = function() return state_dir .. '/debug.log' end; require('nvim-claude').setup({ provider = { name = 'opencode', opencode = {} }, mcp = { auto_install = false } }); require('nvim-claude.settings-updater').update_claude_settings()"

nvim --headless --listen "$SOCKET" --cmd "set runtimepath+=$ROOT_DIR" -u "$ROOT_DIR/tests/minimal_init.lua" \
  +"lua $setup_lua" >"$NVIM_LOG" 2>&1 &
NVIM_PID=$!

PLUGIN_FILE="$CONFIG_DIR/opencode/plugins/nvim-claude.js"
SERVER_FILE=""

for _ in $(seq 1 100); do
  for candidate in "$RUNTIME_DIR"/nvim-claude-*-server; do
    if [ -s "$candidate" ]; then
      SERVER_FILE="$candidate"
      break
    fi
  done
  if [ -s "$PLUGIN_FILE" ] && [ -n "$SERVER_FILE" ]; then
    break
  fi
  if ! kill -0 "$NVIM_PID" >/dev/null 2>&1; then
    printf 'Neovim exited early. Log:\n' >&2
    cat "$NVIM_LOG" >&2
    exit 1
  fi
  sleep 0.05
done

if [ ! -s "$PLUGIN_FILE" ]; then
  printf 'Generated OpenCode plugin not found at %s\nNeovim log:\n' "$PLUGIN_FILE" >&2
  cat "$NVIM_LOG" >&2
  exit 1
fi

if [ -z "$SERVER_FILE" ]; then
  printf 'Neovim server file not found in %s\nNeovim log:\n' "$RUNTIME_DIR" >&2
  cat "$NVIM_LOG" >&2
  exit 1
fi

node --check "$PLUGIN_FILE"
node "$ROOT_DIR/scripts/opencode_event_driver.mjs" \
  --repo="$REPO" \
  --plugin="$PLUGIN_FILE" \
  --rpc="$ROOT_DIR/rpc/nvim-rpc.sh"

printf 'OpenCode integration harness passed.\n'
