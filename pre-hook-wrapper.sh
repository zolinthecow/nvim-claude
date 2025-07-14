#!/bin/bash
# Pre-hook wrapper for nvim-claude
# This script is called by Claude Code before file editing tools

# Debug log file
DEBUG_LOG="/tmp/nvim-claude-hook-debug.log"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Log the input for debugging
echo "=== $(date) ===" >> "$DEBUG_LOG"
echo "PRE-HOOK JSON Input:" >> "$DEBUG_LOG"
echo "$JSON_INPUT" >> "$DEBUG_LOG"

# Extract file_path from tool_input.file_path
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

echo "PRE-HOOK Extracted FILE_PATH: $FILE_PATH" >> "$DEBUG_LOG"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the proxy script with the file path
if [ -n "$FILE_PATH" ]; then
    # Escape single quotes and backslashes in file path for Lua
    FILE_PATH_ESCAPED=$(echo "$FILE_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
    echo "PRE-HOOK Calling nvr with: $FILE_PATH_ESCAPED" >> "$DEBUG_LOG"
    
    # Execute the pre-hook with file path
    echo "PRE-HOOK Executing pre hook with file path..." >> "$DEBUG_LOG"
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').pre_tool_use_hook('$FILE_PATH_ESCAPED')\")" 2>&1 | tee -a "$DEBUG_LOG"
    echo "PRE-HOOK pre hook complete" >> "$DEBUG_LOG"
else
    echo "PRE-HOOK No file path found, calling without argument" >> "$DEBUG_LOG"
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require(\"nvim-claude.hooks\").pre_tool_use_hook()")'
fi

# Return the exit code from nvr
exit $?