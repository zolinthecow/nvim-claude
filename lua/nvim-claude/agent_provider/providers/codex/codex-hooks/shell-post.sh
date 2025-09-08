#!/usr/bin/env bash

# Codex shell post-hook: untrack files if delete failed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

if [ "$#" -gt 0 ] && [[ "${!#}" == "{"* ]]; then JSON_INPUT="${!#}"; else JSON_INPUT=$(cat); fi
set_project_log_from_json "$JSON_INPUT"
log "[codex shell-post] called"

TOOL=$(echo "$JSON_INPUT" | jq -r '.tool // empty' 2>/dev/null)
RAW=$(echo "$JSON_INPUT" | jq -r '.arguments.raw // empty' 2>/dev/null)
ARGSTR=$(echo "$JSON_INPUT" | jq -r 'if (.arguments|type)=="string" then .arguments else "" end' 2>/dev/null)
CMD=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$CMD" ]; then CMD="$RAW"; fi
if [ -z "$CMD" ]; then CMD="$ARGSTR"; fi
SUCCESS=$(echo "$JSON_INPUT" | jq -r '.success // empty' 2>/dev/null)
OUTPUT_HEAD=$(echo "$JSON_INPUT" | jq -r '.output // empty' 2>/dev/null)
OUTPUT_HEAD="${OUTPUT_HEAD:0:120}"
SUB_ID=$(echo "$JSON_INPUT" | jq -r '.sub_id // empty' 2>/dev/null)
CALL_ID=$(echo "$JSON_INPUT" | jq -r '.call_id // empty' 2>/dev/null)
CWD=$(echo "$JSON_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
GIT_ROOT=$(echo "$JSON_INPUT" | jq -r '.git_root // empty' 2>/dev/null)
if [ -z "$CWD" ]; then CWD=$(pwd); fi
if [ -z "$GIT_ROOT" ] || [ "$GIT_ROOT" = "null" ]; then GIT_ROOT="$CWD"; fi
log "[codex shell-post] tool=$TOOL cmd=${CMD:0:200} success=$SUCCESS out=${OUTPUT_HEAD}"
PAYLOAD_DELETED=$(echo "$JSON_INPUT" | jq -r '.deleted[]? // empty' 2>/dev/null)
if [ -n "$PAYLOAD_DELETED" ]; then
  # Deleted list provided; nothing to untrack (successful deletions). Optionally log
  CNT=$(printf '%s\n' "$PAYLOAD_DELETED" | awk 'NF' | wc -l | tr -d ' ')
  log "[codex shell-post] payload deleted count: $CNT"
elif [[ "$CMD" =~ ^rm[[:space:]] ]]; then
  LS_COMMAND=$(echo "$CMD" | sed 's/^rm /ls -d /')
  log "[codex shell-post] ls command: $LS_COMMAND"
  FILES_OUTPUT=$(eval "$LS_COMMAND" 2>/dev/null)
  PLUGIN_ROOT="$(get_plugin_root)"
  CNT=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    ABS=$(realpath "$file" 2>/dev/null || echo "$file")
    if [ -e "$ABS" ]; then
      B64=$(printf '%s' "$ABS" | base64)
      log "[codex shell-post] untrack failed delete: $ABS"
      TARGET_FILE="$ABS" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').untrack_failed_deletion_b64('$B64')\")" >/dev/null 2>&1
      CNT=$((CNT+1))
    fi
  done <<< "$FILES_OUTPUT"
  log "[codex shell-post] rm still-present files: $CNT"
fi

# If not an rm command, scope modified files since pre using sentinel and mark as edited
if ! [[ "$CMD" =~ ^rm[[:space:]] ]]; then
  TMP_BASE="${TMPDIR:-/tmp}/nvim-claude-codex-hooks"
  TS_FILE="$TMP_BASE/calls/${SUB_ID:-0}-${CALL_ID}.ts"
  if [ -f "$TS_FILE" ]; then
    CHANGED=$(find "$CWD" -type f -newer "$TS_FILE" 2>/dev/null)
    PLUGIN_ROOT="$(get_plugin_root)"
    N=0
    while IFS= read -r ABS; do
      [ -z "$ABS" ] && continue
      if command -v realpath >/dev/null 2>&1; then ABS=$(realpath "$ABS" 2>/dev/null || echo "$ABS"); fi
      PATH_B64=$(printf '%s' "$ABS" | base64)
      log "[codex shell-post] marking edited (since pre): $ABS"
      TARGET_FILE="$GIT_ROOT" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('$PATH_B64')\")" >/dev/null 2>&1
      N=$((N+1))
    done <<< "$CHANGED"
    log "[codex shell-post] since-pre edited count: $N"
    rm -f "$TS_FILE" 2>/dev/null || true
  fi
fi

echo "[codex shell-post] done" >> "$LOG_FILE"
exit 0
