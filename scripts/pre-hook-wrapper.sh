#!/bin/bash
# Pre-hook wrapper for nvim-claude
# This script is called by Claude Code before file editing tools

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Extract file_path from tool_input.file_path
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the proxy script with the file path
if [ -n "$FILE_PATH" ]; then
    # Base64 encode the file path to avoid escaping issues
    FILE_PATH_B64=$(echo -n "$FILE_PATH" | base64)
    # Execute the pre-hook with base64 encoded file path
    TARGET_FILE="$FILE_PATH" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').pre_tool_use_hook_b64('$FILE_PATH_B64')\")"
else
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require(\"nvim-claude.hooks\").pre_tool_use_hook_b64()")'
fi

# Return the exit code from nvr
exit $?