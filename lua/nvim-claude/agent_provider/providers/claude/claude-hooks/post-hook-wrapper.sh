#!/bin/bash
# Wrapper script for PostToolUse hook that extracts file_path from stdin

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common helpers
source "$SCRIPT_DIR/hook-common.sh"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Switch logging to project-specific debug log
set_project_log_from_json "$JSON_INPUT"

log "post-hook-wrapper called"

# Extract file_path from tool_response.filePath
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_response.filePath // empty' 2>/dev/null || echo "")
log "Extracted FILE_PATH: $FILE_PATH"

if [ -n "$FILE_PATH" ]; then
    FILE_PATH_B64=$(printf '%s' "$FILE_PATH" | base64)
    PLUGIN_ROOT="$(get_plugin_root)"
    RESULT=$(TARGET_FILE="$FILE_PATH" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('$FILE_PATH_B64')\")" 2>&1)
else
    PLUGIN_ROOT="$(get_plugin_root)"
    "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval('require(\"nvim-claude.events.adapter\").post_tool_use_b64()')"
fi
