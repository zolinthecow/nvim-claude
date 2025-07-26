#!/bin/bash

# User prompt submit hook wrapper for nvim-claude
# This is called by Claude Code when a user submits a prompt

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON input from stdin
JSON_INPUT=$(cat)

log "UserPromptSubmit hook called"
log "Raw JSON input: $JSON_INPUT"

# Extract prompt from JSON using jq
PROMPT=$(echo "$JSON_INPUT" | jq -r '.prompt // empty')

if [ -z "$PROMPT" ]; then
    log "ERROR: No prompt found in JSON input"
    PROMPT=""
fi

log "Extracted prompt: ${PROMPT:0:100}..."

# Use a default target file in the nvim-claude project
TARGET_FILE="/Users/colinzhao/dots/.config/nvim/lua/nvim-claude/init.lua"
log "Using target file: $TARGET_FILE"

# Base64 encode the prompt to avoid all escaping issues
PROMPT_B64=$(echo -n "$PROMPT" | base64)

# Call the hook function with base64 encoded prompt
log "Calling nvr-proxy with user_prompt_submit_hook_b64"
TARGET_FILE="$TARGET_FILE" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').user_prompt_submit_hook_b64('$PROMPT_B64')\")" 2>&1 | tee -a "$LOG_FILE"

# Always exit successfully
exit 0