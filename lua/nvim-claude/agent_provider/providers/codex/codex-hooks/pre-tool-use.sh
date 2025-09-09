#!/usr/bin/env bash

# Codex PreToolUse hook: ensure baseline exists and create per-call sentinel

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON from last arg when provided; fallback to stdin
if [ "$#" -gt 0 ] && [[ "${!#}" == "{"* ]]; then
  JSON_INPUT="${!#}"
else
  JSON_INPUT=$(cat)
fi
set_project_log_from_json "$JSON_INPUT"
log "[codex pre-tool-use] called"

# Derive project CWD
CWD=$(echo "$JSON_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then CWD=$(pwd); fi

# Create a per-call sentinel to help post hook scope file changes
SUB_ID=$(echo "$JSON_INPUT" | jq -r '.sub_id // empty' 2>/dev/null)
CALL_ID=$(echo "$JSON_INPUT" | jq -r '.call_id // empty' 2>/dev/null)
TOOL=$(echo "$JSON_INPUT" | jq -r '.tool // empty' 2>/dev/null)
log "[codex pre-tool-use] ids sub=$SUB_ID call=$CALL_ID tool=$TOOL"
if [ -n "$CALL_ID" ]; then
  TMP_BASE="${TMPDIR:-/tmp}/nvim-claude-codex-hooks"
  mkdir -p "$TMP_BASE/calls" 2>/dev/null || true
  TOUCH_FILE="$TMP_BASE/calls/${SUB_ID:-0}-${CALL_ID}.ts"
  : > "$TOUCH_FILE"
  log "[codex pre-tool-use] touch $TOUCH_FILE"
fi

# If pre.targets are provided by Codex, persist and pre-touch baseline for each target
TARGETS=$(echo "$JSON_INPUT" | jq -r '.targets[]? // empty' 2>/dev/null)
if [ -n "$TARGETS" ]; then
  TMP_BASE="${TMPDIR:-/tmp}/nvim-claude-codex-hooks"
  mkdir -p "$TMP_BASE/calls" 2>/dev/null || true
  CALL_FILE="$TMP_BASE/calls/${SUB_ID:-0}-${CALL_ID}.files"
  : > "$CALL_FILE"
  printf '%s\n' "$TARGETS" | awk 'NF' | sort -u > "$CALL_FILE"
  log "[codex pre-tool-use] targets saved: $CALL_FILE ($(wc -l < "$CALL_FILE" 2>/dev/null || echo 0) paths)"
  # Pre-touch baseline for each target file (absolute paths expected)
  PLUGIN_ROOT="$(get_plugin_root)"
  while IFS= read -r ABS; do
    [ -z "$ABS" ] && continue
    B64=$(printf '%s' "$ABS" | base64)
    TARGET_FILE="$ABS" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').pre_tool_use_b64('$B64')\")" >/dev/null 2>&1
  done < "$CALL_FILE"
fi

# Route RPC using the project directory to ensure baseline exists even without targets
TARGET_FILE="$CWD"
log "[codex pre-tool-use] TARGET_FILE=$TARGET_FILE"

# Call pre_tool_use without a specific path (baseline creation)
PLUGIN_ROOT="$(get_plugin_root)"
TARGET_FILE="$TARGET_FILE" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval('require(\"nvim-claude.events.adapter\").pre_tool_use_b64()')" 2>&1 | tee -a "$LOG_FILE" >/dev/null
log "[codex pre-tool-use] done"

exit 0
