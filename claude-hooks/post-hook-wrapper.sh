#!/bin/bash
# Wrapper script for PostToolUse hook that extracts file_path from stdin

LOG_FILE="$HOME/.local/share/nvim/nvim-claude-hooks.log"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

echo "[$(date)] post-hook-wrapper called" >> "$LOG_FILE"

# Extract file_path from tool_response.filePath
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_response.filePath // empty' 2>/dev/null || echo "")
echo "[$(date)] Extracted FILE_PATH: $FILE_PATH" >> "$LOG_FILE"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$FILE_PATH" ]; then
    FILE_PATH_B64=$(printf '%s' "$FILE_PATH" | base64)
    RESULT=$(TARGET_FILE="$FILE_PATH" "$SCRIPT_DIR/../rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('$FILE_PATH_B64')\")" 2>&1)
else
    "$SCRIPT_DIR/../rpc/nvim-rpc.sh" --remote-expr "luaeval('require(\"nvim-claude.events.adapter\").post_tool_use_b64()')"
fi
