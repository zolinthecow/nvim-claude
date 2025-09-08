#!/usr/bin/env bash

# Codex UserPromptSubmit hook: create a checkpoint with prompt text

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON from last arg when provided; fallback to stdin
if [ "$#" -gt 0 ] && [[ "${!#}" == "{"* ]]; then
  JSON_INPUT="${!#}"
else
  JSON_INPUT=$(cat)
fi
set_project_log_from_json "$JSON_INPUT"
log "[codex user-prompt-submit] called"

SUB_ID=$(echo "$JSON_INPUT" | jq -r '.sub_id // empty' 2>/dev/null)
CALL_ID=$(echo "$JSON_INPUT" | jq -r '.call_id // empty' 2>/dev/null)
CWD=$(echo "$JSON_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
GIT_ROOT=$(echo "$JSON_INPUT" | jq -r '.git_root // empty' 2>/dev/null)
if [ -z "$CWD" ]; then CWD=$(pwd); fi
if [ -z "$GIT_ROOT" ] || [ "$GIT_ROOT" = "null" ]; then GIT_ROOT="$CWD"; fi

# Join texts array items with double newlines
PROMPT=$(echo "$JSON_INPUT" | jq -r '[.texts[]? // empty] | join("\n\n")' 2>/dev/null)
if [ "$PROMPT" = "null" ] || [ -z "$PROMPT" ]; then PROMPT=""; fi
log "[codex user-prompt-submit] ids sub=$SUB_ID call=$CALL_ID"
log "[codex user-prompt-submit] paths cwd=$CWD git_root=$GIT_ROOT"
log "[codex user-prompt-submit] prompt head: ${PROMPT:0:120}"

# Route to the correct Neovim instance using git_root/cwd
TARGET_FILE="$GIT_ROOT"
log "[codex user-prompt-submit] TARGET_FILE=$TARGET_FILE"

PROMPT_B64=$(printf '%s' "$PROMPT" | base64)
PLUGIN_ROOT="$(get_plugin_root)"
TARGET_FILE="$TARGET_FILE" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').user_prompt_submit_b64('$PROMPT_B64')\")" 2>&1 | tee -a "$LOG_FILE" >/dev/null
log "[codex user-prompt-submit] done"

exit 0
