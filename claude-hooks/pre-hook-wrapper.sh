#!/bin/bash
# Pre-hook wrapper for nvim-claude
# This script is called by Claude Code before file editing tools

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common helpers
source "$SCRIPT_DIR/hook-common.sh"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Switch logging to project-specific debug log
set_project_log_from_json "$JSON_INPUT"

log "Pre-hook wrapper called"
log "JSON input: $JSON_INPUT"

# Extract file_path from tool_input.file_path
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

# Call the proxy script with the file path via events adapter
if [ -n "$FILE_PATH" ]; then
    FILE_PATH_B64=$(printf '%s' "$FILE_PATH" | base64)
    TARGET_FILE="$FILE_PATH" "$SCRIPT_DIR/../rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').pre_tool_use_b64('$FILE_PATH_B64')\")"
else
    "$SCRIPT_DIR/../rpc/nvim-rpc.sh" --remote-expr "luaeval('require(\"nvim-claude.events.adapter\").pre_tool_use_b64()')"
fi

# Return the exit code from nvim-rpc
exit $?
