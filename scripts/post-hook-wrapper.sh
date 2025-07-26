#!/bin/bash
# Wrapper script for PostToolUse hook that extracts file_path from stdin

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Extract file_path from tool_response.filePath
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_response.filePath // empty' 2>/dev/null || echo "")

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the proxy script with the file path
if [ -n "$FILE_PATH" ]; then
    # Base64 encode the file path to avoid escaping issues
    FILE_PATH_B64=$(echo -n "$FILE_PATH" | base64)
    
    # Execute the actual command using remote-expr with base64 encoded path
    TARGET_FILE="$FILE_PATH" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').post_tool_use_hook_b64('$FILE_PATH_B64')\")"
else
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require(\"nvim-claude.hooks\").post_tool_use_hook_b64()")'
fi