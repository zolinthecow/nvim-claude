#!/usr/bin/env bash

# Codex Stop hook validator: reuse provider-neutral logic via RPC/MCP

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON from last arg when provided; fallback to stdin
if [ "$#" -gt 0 ] && [[ "${!#}" == "{"* ]]; then
  INPUT="${!#}"
else
  INPUT=$(cat)
fi
set_project_log_from_json "$INPUT"

SUB_ID=$(echo "$INPUT" | jq -r '.sub_id // empty' 2>/dev/null)
CALL_ID=$(echo "$INPUT" | jq -r '.call_id // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
GIT_ROOT=$(echo "$INPUT" | jq -r '.git_root // empty' 2>/dev/null)
if [ -z "$CWD" ]; then CWD=$(pwd); fi
if [ -z "$GIT_ROOT" ] || [ "$GIT_ROOT" = "null" ]; then GIT_ROOT="$CWD"; fi
log "[codex stop] called sub=$SUB_ID call=$CALL_ID cwd=$CWD git_root=$GIT_ROOT"
if [ -z "$CWD" ]; then CWD=$(pwd); fi

# Use the existing validator logic from Claude provider via RPC helpers
# This script duplicates semantics with provider-local path resolution

PROJECT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$PROJECT_ROOT" ]; then PROJECT_ROOT="$CWD"; fi
cd "$PROJECT_ROOT" 2>/dev/null || true

PROJECT_ROOT_KEY="$PROJECT_ROOT"
if command -v python3 >/dev/null 2>&1; then
  PROJECT_ROOT_KEY=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PROJECT_ROOT")
elif command -v realpath >/dev/null 2>&1; then
  PROJECT_ROOT_KEY=$(realpath "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")
fi

MCP_PYTHON="$HOME/.local/share/nvim/nvim-claude/mcp-env/bin/python"
if [ ! -f "$MCP_PYTHON" ]; then
  log "[codex stop] MCP venv missing at $MCP_PYTHON; approving"
  echo '{"decision": "approve"}'
  exit 0
fi

PROJECT_STATE_DIR="$HOME/.local/share/nvim/nvim-claude/projects"
STATE_FILE="$PROJECT_STATE_DIR/state.json"

if [ -f "$STATE_FILE" ]; then
  SESSION_FILES=$(jq -r --arg cwd "$PROJECT_ROOT_KEY" '.[$cwd].session_edited_files // [] | .[]' "$STATE_FILE" 2>/dev/null)
  if [ -z "$SESSION_FILES" ]; then
    log "[codex stop] no session files; approving"
    echo '{"decision": "approve"}'
    exit 0
  fi
  FILE_LIST=()
  while IFS= read -r f; do [ -n "$f" ] && FILE_LIST+=("$f"); done <<< "$SESSION_FILES"
  START_TS=$(date +%s)
  log "[codex stop] checking diagnostics for ${#FILE_LIST[@]} files (single session)"
  PLUGIN_ROOT="$(get_plugin_root)"
  RESULT_JSON=$("$MCP_PYTHON" "$PLUGIN_ROOT/rpc/check-diagnostics.py" "${FILE_LIST[@]}" 2>/dev/null)
  TOTAL_ERRORS=$(echo "$RESULT_JSON" | jq -r '.errors // 0')
  TOTAL_WARNINGS=$(echo "$RESULT_JSON" | jq -r '.warnings // 0')
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  log "[codex stop] diagnostics done errors=$TOTAL_ERRORS warnings=$TOTAL_WARNINGS elapsed=${ELAPSED}s"
  if [ "$TOTAL_ERRORS" -gt 0 ]; then
    SESSION_JSON=$("$MCP_PYTHON" "$PLUGIN_ROOT/rpc/get-session-diagnostics.py" 2>/dev/null)
    JSON_REASON=$(printf '%s' "$SESSION_JSON" | jq -Rs .)
    echo "{\"decision\":\"block\",\"reason\":$JSON_REASON}"
  else
    TARGET_FILE="$GIT_ROOT"
    TARGET_FILE_B64=$(echo -n "$TARGET_FILE" | base64)
    PLUGIN_ROOT="$(get_plugin_root)"
    TARGET_FILE="$TARGET_FILE" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').clear_turn_files_for_path_b64('$TARGET_FILE_B64')\")" >/dev/null 2>&1 || true
    echo '{"decision": "approve"}'
  fi
else
  log "[codex stop] no state file; approving"
  echo '{"decision": "approve"}'
fi

exit 0
