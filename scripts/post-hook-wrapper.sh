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
    # Escape single quotes and backslashes in file path for Lua
    FILE_PATH_ESCAPED=$(echo "$FILE_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
    
    # Execute the actual command using remote-expr
    TARGET_FILE="$FILE_PATH" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').post_tool_use_hook('$FILE_PATH_ESCAPED')\")"
else
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require(\"nvim-claude.hooks\").post_tool_use_hook()")'
fi