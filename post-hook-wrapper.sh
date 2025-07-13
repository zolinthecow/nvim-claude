#!/bin/bash
# Wrapper script for PostToolUse hook that extracts file_path from stdin

# Debug log file
DEBUG_LOG="/tmp/nvim-claude-hook-debug.log"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Log the input for debugging
echo "=== $(date) ===" >> "$DEBUG_LOG"
echo "JSON Input:" >> "$DEBUG_LOG"
echo "$JSON_INPUT" >> "$DEBUG_LOG"

# Extract file_path from tool_response.filePath
FILE_PATH=$(echo "$JSON_INPUT" | jq -r '.tool_response.filePath // empty' 2>/dev/null || echo "")

echo "Extracted FILE_PATH: $FILE_PATH" >> "$DEBUG_LOG"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the proxy script with the file path
if [ -n "$FILE_PATH" ]; then
    # Escape single quotes and backslashes in file path for Lua
    FILE_PATH_ESCAPED=$(echo "$FILE_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
    echo "Calling nvr with: $FILE_PATH_ESCAPED" >> "$DEBUG_LOG"
    COMMAND="<C-\\\\><C-N>:lua require('nvim-claude.hooks').post_tool_use_hook('$FILE_PATH_ESCAPED')<CR>"
    echo "Full command: $COMMAND" >> "$DEBUG_LOG"
    
    # Test if we can reach neovim
    echo "Testing neovim connection..." >> "$DEBUG_LOG"
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "1+1" 2>&1 >> "$DEBUG_LOG"
    
    # Execute the actual command using remote-expr instead of remote-send
    echo "Executing post hook..." >> "$DEBUG_LOG"
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').post_tool_use_hook('$FILE_PATH_ESCAPED')\")" 2>&1 | tee -a "$DEBUG_LOG"
    echo "Post hook complete" >> "$DEBUG_LOG"
else
    echo "No file path found, calling without argument" >> "$DEBUG_LOG"
    "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require(\"nvim-claude.hooks\").post_tool_use_hook()")'
fi