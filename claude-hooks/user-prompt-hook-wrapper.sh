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

# Get the current working directory from the JSON input or use current directory
CWD=$(echo "$JSON_INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
    CWD=$(pwd)
fi

# Find any file in the current project to use as TARGET_FILE
# This helps nvim-rpc find the correct Neovim instance for this project
if [ -d "$CWD" ]; then
    # Try to find a file in the project (prefer existing files)
    TARGET_FILE=$(find "$CWD" -type f -name "*.md" -o -name "*.txt" -o -name "*.lua" -o -name "*.js" 2>/dev/null | head -1)
    if [ -z "$TARGET_FILE" ]; then
        # Fallback to any file in the project
        TARGET_FILE=$(find "$CWD" -type f 2>/dev/null | head -1)
    fi
fi

# If still no file found, use the CWD itself
if [ -z "$TARGET_FILE" ]; then
    TARGET_FILE="$CWD"
fi

log "Using target file: $TARGET_FILE"

# Base64 encode the prompt to avoid all escaping issues
PROMPT_B64=$(echo -n "$PROMPT" | base64)

# Call the hook function with base64 encoded prompt
log "Calling nvim-rpc with user_prompt_submit_hook_b64"
TARGET_FILE="$TARGET_FILE" "$SCRIPT_DIR/../rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').user_prompt_submit_b64('$PROMPT_B64')\")" 2>&1 | tee -a "$LOG_FILE"

# Always exit successfully
exit 0
