#!/usr/bin/env bash

# Codex shell pre-hook: track deletions pre-rm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON
if [ "$#" -gt 0 ] && [[ "${!#}" == "{"* ]]; then JSON_INPUT="${!#}"; else JSON_INPUT=$(cat); fi
set_project_log_from_json "$JSON_INPUT"
log "[codex shell-pre] called"

TOOL=$(echo "$JSON_INPUT" | jq -r '.tool // empty' 2>/dev/null)
RAW=$(echo "$JSON_INPUT" | jq -r '.arguments.raw // empty' 2>/dev/null)
ARGSTR=$(echo "$JSON_INPUT" | jq -r 'if (.arguments|type)=="string" then .arguments else "" end' 2>/dev/null)
ARGVSTR=$(echo "$JSON_INPUT" | jq -r '(.arguments.argv // []) | join(" ")' 2>/dev/null)
ARGTYPE=$(echo "$JSON_INPUT" | jq -r '(.arguments|type) // empty' 2>/dev/null)
ARGKEYS=$(echo "$JSON_INPUT" | jq -r '(.arguments|keys // []) | join(",")' 2>/dev/null)
CMD=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [ -z "$CMD" ]; then CMD="$RAW"; fi
if [ -z "$CMD" ]; then CMD="$ARGSTR"; fi
if [ -z "$CMD" ]; then CMD="$ARGVSTR"; fi
SUB_ID=$(echo "$JSON_INPUT" | jq -r '.sub_id // empty' 2>/dev/null)
CALL_ID=$(echo "$JSON_INPUT" | jq -r '.call_id // empty' 2>/dev/null)
CWD=$(echo "$JSON_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then CWD=$(pwd); fi

# Create per-call timestamp sentinel to scope changes in post
if [ -n "$CALL_ID" ]; then
  TMP_BASE="${TMPDIR:-/tmp}/nvim-claude-codex-hooks"
  mkdir -p "$TMP_BASE/calls" 2>/dev/null || true
  TS_FILE="$TMP_BASE/calls/${SUB_ID:-0}-${CALL_ID}.ts"
  : > "$TS_FILE"
  log "[codex shell-pre] touch $TS_FILE"
fi
log "[codex shell-pre] tool=$TOOL argtype=$ARGTYPE argkeys=$ARGKEYS cmd=${CMD:0:200}"
TARGETS=$(echo "$JSON_INPUT" | jq -r '.targets[]? // empty' 2>/dev/null)
if [ -n "$TARGETS" ]; then
  # Use payload-provided rm targets directly
  PLUGIN_ROOT="$(get_plugin_root)"
  COUNT=0
  while IFS= read -r ABS; do
    [ -z "$ABS" ] && continue
    log "[codex shell-pre] track delete (payload): $ABS"
    B64=$(printf '%s' "$ABS" | base64)
    TARGET_FILE="$ABS" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').track_deleted_file_b64('$B64')\")" >/dev/null 2>&1
    COUNT=$((COUNT+1))
  done <<< "$TARGETS"
  log "[codex shell-pre] rm targets tracked (payload): $COUNT"
elif [[ "$CMD" =~ ^rm[[:space:]] ]]; then
  # Resolve target list (best effort)
  LS_COMMAND=$(echo "$CMD" | sed 's/^rm /ls -d /')
  log "[codex shell-pre] ls command: $LS_COMMAND"
  FILES_OUTPUT=$(eval "$LS_COMMAND" 2>/dev/null)
  PLUGIN_ROOT="$(get_plugin_root)"
  COUNT=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    ABS=$(realpath "$file" 2>/dev/null || echo "$file")
    if [ -e "$ABS" ]; then
      B64=$(printf '%s' "$ABS" | base64)
      log "[codex shell-pre] track delete: $ABS"
      TARGET_FILE="$ABS" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').track_deleted_file_b64('$B64')\")" >/dev/null 2>&1
      COUNT=$((COUNT+1))
    fi
  done <<< "$FILES_OUTPUT"
  log "[codex shell-pre] rm targets tracked: $COUNT"
fi

# For shell apply_patch invoked via command string, parse targets and pre-touch baseline per file
GIT_ROOT=$(echo "$JSON_INPUT" | jq -r '.git_root // empty' 2>/dev/null)
if [ -z "$GIT_ROOT" ] || [ "$GIT_ROOT" = "null" ]; then GIT_ROOT="$CWD"; fi
if [[ "$CMD" == apply_patch* ]]; then
  PATCH_TEXT="${CMD#apply_patch }"
  PLUGIN_ROOT="$(get_plugin_root)"
  COUNT_AP=0
  # Persist per-call absolute target list for post hook
  TMP_BASE="${TMPDIR:-/tmp}/nvim-claude-codex-hooks"
  mkdir -p "$TMP_BASE/calls" 2>/dev/null || true
  CALL_FILE="$TMP_BASE/calls/${SUB_ID:-0}-${CALL_ID}.files"
  : > "$CALL_FILE"
  while IFS= read -r line; do
    case "$line" in
      "*** Update File: "*) rel=${line#*** Update File: };;
      "*** Add File: "*) rel=${line#*** Add File: };;
      "*** Delete File: "*) rel=${line#*** Delete File: };;
      *) rel="";;
    esac
    if [ -n "$rel" ]; then
      abs="$GIT_ROOT/$rel"
      # normalize
      if command -v realpath >/dev/null 2>&1; then abs=$(realpath "$abs" 2>/dev/null || echo "$abs"); fi
      printf '%s\n' "$abs" >> "$CALL_FILE"
      b64=$(printf '%s' "$abs" | base64)
      log "[codex shell-pre] apply_patch target: $abs"
      TARGET_FILE="$abs" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').pre_tool_use_b64('$b64')\")" >/dev/null 2>&1
      COUNT_AP=$((COUNT_AP+1))
    fi
  done < <(printf '%s\n' "$PATCH_TEXT")
  # Dedup list
  if [ -f "$CALL_FILE" ]; then sort -u "$CALL_FILE" -o "$CALL_FILE"; fi
  log "[codex shell-pre] apply_patch targets pre-touched: $COUNT_AP (saved: $CALL_FILE)"
fi

echo "[codex shell-pre] done" >> "$LOG_FILE"
exit 0
