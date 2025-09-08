#!/usr/bin/env bash

# Codex PostToolUse hook: mark edited files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON from last arg when provided; fallback to stdin
if [ "$#" -gt 0 ] && [[ "${!#}" == "{"* ]]; then
  JSON_INPUT="${!#}"
else
  JSON_INPUT=$(cat)
fi
set_project_log_from_json "$JSON_INPUT"
TOOL=$(echo "$JSON_INPUT" | jq -r '.tool // empty' 2>/dev/null)
SUCCESS=$(echo "$JSON_INPUT" | jq -r '.success // empty' 2>/dev/null)
log "[codex post-tool-use] called tool=$TOOL success=$SUCCESS"

CWD=$(echo "$JSON_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
GIT_ROOT=$(echo "$JSON_INPUT" | jq -r '.git_root // empty' 2>/dev/null)
if [ -z "$CWD" ]; then CWD=$(pwd); fi
if [ -z "$GIT_ROOT" ] || [ "$GIT_ROOT" = "null" ]; then GIT_ROOT="$CWD"; fi

# If a pre-hook saved specific files for this call, prefer those
SUB_ID=$(echo "$JSON_INPUT" | jq -r '.sub_id // empty' 2>/dev/null)
CALL_ID=$(echo "$JSON_INPUT" | jq -r '.call_id // empty' 2>/dev/null)
TMP_BASE="${TMPDIR:-/tmp}/nvim-claude-codex-hooks"
CALL_FILE="$TMP_BASE/calls/${SUB_ID:-0}-${CALL_ID}.files"
USE_CALL_FILES=false
if [ -n "$CALL_ID" ] && [ -f "$CALL_FILE" ]; then
  USE_CALL_FILES=true
  log "[codex post-tool-use] using call file list: $CALL_FILE"
fi

# Prefer payload-provided file lists (edited/created/deleted/renamed)
PAYLOAD_FILES=$(echo "$JSON_INPUT" | jq -r '[ (.edited // [][])[], (.created // [][])[], (.deleted // [][])[], ((.renamed // [][])[] | objects | .to // empty) ] | unique | .[]' 2>/dev/null)
USE_PAYLOAD=false
if [ -n "$PAYLOAD_FILES" ]; then
  USE_PAYLOAD=true
  ECOUNT=$(echo "$JSON_INPUT" | jq -r '(.edited // [] | length)')
  DCOUNT=$(echo "$JSON_INPUT" | jq -r '(.deleted // [] | length)')
  CCOUNT=$(echo "$JSON_INPUT" | jq -r '(.created // [] | length)')
  RCOUNT=$(echo "$JSON_INPUT" | jq -r '(.renamed // [] | length)')
  log "[codex post-tool-use] using payload lists: edited=$ECOUNT deleted=$DCOUNT created=$CCOUNT renamed=$RCOUNT"
fi

# Collect changed files robustly (modified, staged, and untracked) if no payload or call-specific list
if [ "$USE_PAYLOAD" = false ] && [ "$USE_CALL_FILES" = false ]; then
  CHANGED=$( {
    git -C "$CWD" diff --name-only 2>/dev/null;
    git -C "$CWD" diff --name-only --cached 2>/dev/null;
    git -C "$CWD" ls-files -m 2>/dev/null;
    git -C "$CWD" ls-files --others --exclude-standard 2>/dev/null;
  } | sort -u )
  if [ -z "$CHANGED" ]; then
    log "[codex post-tool-use] no changed files detected"
    echo "[codex post-tool-use] done" >> "$LOG_FILE"
    exit 0
  fi
fi

PLUGIN_ROOT="$(get_plugin_root)"
COUNT=0
if [ "$USE_PAYLOAD" = true ]; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in /*) ABS="$p" ;; *) ABS="$GIT_ROOT/$p" ;; esac
    if command -v realpath >/dev/null 2>&1; then ABS=$(realpath "$ABS" 2>/dev/null || echo "$ABS"); fi
    # For deletions, file may not exist; still mark edited to show diff vs baseline
    COUNT=$((COUNT+1))
    PATH_B64=$(printf '%s' "$ABS" | base64)
    log "[codex post-tool-use] marking edited (payload): $ABS"
    TARGET_FILE="$GIT_ROOT" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('$PATH_B64')\")" 2>&1 | tee -a "$LOG_FILE" >/dev/null
  done <<< "$PAYLOAD_FILES"
elif [ "$USE_CALL_FILES" = true ]; then
  # If we only have a sentinel timestamp file, use it to scope by mtime
  if [ ! -s "$CALL_FILE" ] && [ -f "${CALL_FILE%.files}.ts" ]; then
    TS_FILE="${CALL_FILE%.files}.ts"
    log "[codex post-tool-use] using timestamp filter: $TS_FILE"
    CHANGED=$(find "$CWD" -type f -newer "$TS_FILE" 2>/dev/null | sed "s,^$CWD/,," | sort -u)
    USE_CALL_FILES=false
  fi
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    ABS="$CWD/$rel"
    if command -v realpath >/dev/null 2>&1; then ABS=$(realpath "$ABS" 2>/dev/null || echo "$ABS"); fi
    if [ -e "$ABS" ]; then
      COUNT=$((COUNT+1))
      PATH_B64=$(printf '%s' "$ABS" | base64)
      log "[codex post-tool-use] marking edited (call): $ABS"
      TARGET_FILE="$GIT_ROOT" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('$PATH_B64')\")" 2>&1 | tee -a "$LOG_FILE" >/dev/null
    fi
  done < "$CALL_FILE"
  rm -f "$CALL_FILE" 2>/dev/null || true
else
  while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  ABS="$CWD/$rel"
  # Normalize absolute path
  if command -v realpath >/dev/null 2>&1; then
    ABS=$(realpath "$ABS" 2>/dev/null || echo "$ABS")
  fi
  if [ -e "$ABS" ]; then
    COUNT=$((COUNT+1))
    PATH_B64=$(printf '%s' "$ABS" | base64)
    log "[codex post-tool-use] marking edited: $ABS"
    TARGET_FILE="$GIT_ROOT" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('$PATH_B64')\")" 2>&1 | tee -a "$LOG_FILE" >/dev/null
  fi
  done <<< "$CHANGED"
fi

log "[codex post-tool-use] processed $COUNT files"
echo "[codex post-tool-use] done" >> "$LOG_FILE"
exit 0
