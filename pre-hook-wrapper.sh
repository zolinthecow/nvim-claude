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
    # Escape single quotes and backslashes in file path for Lua
    FILE_PATH_ESCAPED=$(echo "$FILE_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
    # Execute the pre-hook with file path
    TARGET_FILE="$FILE_PATH" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').pre_tool_use_hook('$FILE_PATH_ESCAPED')\")"
else
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require(\"nvim-claude.hooks\").pre_tool_use_hook()")'
fi

# Return the exit code from nvr
exit $?