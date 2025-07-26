#!/bin/bash

# Bash hook wrapper for nvim-claude
# This script is called by Claude Code when executing bash commands
# It detects rm commands and notifies Neovim about deleted files

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log file location
LOG_FILE="${HOME}/.local/share/nvim/nvim-claude-hooks.log"

# Log that the hook was called
echo "[bash-hook-wrapper] Hook called at $(date)" >> "$LOG_FILE"
echo "[bash-hook-wrapper] Script dir: $SCRIPT_DIR" >> "$LOG_FILE"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Extract the command from the JSON
COMMAND=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty')

# Log for debugging
echo "[bash-hook-wrapper] Command: $COMMAND" >> "$LOG_FILE"

# Check if it's an rm command
if [[ "$COMMAND" =~ ^rm[[:space:]] ]]; then
    echo "[bash-hook-wrapper] Detected rm command" >> "$LOG_FILE"
    
    # Use ls to get the actual files that rm would target
    # Replace 'rm' with 'ls -d' to get exact file list
    LS_COMMAND=$(echo "$COMMAND" | sed 's/^rm /ls -d /')
    
    echo "[bash-hook-wrapper] Running ls command to find targets: $LS_COMMAND" >> "$LOG_FILE"
    
    # Execute the ls command to get the list of files
    # Use eval to handle complex cases like globs, quotes, etc.
    FILES_OUTPUT=$(eval "$LS_COMMAND" 2>/dev/null)
    
    if [ -n "$FILES_OUTPUT" ]; then
        # Process each file that would be deleted
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                # Get absolute path
                ABS_PATH=$(realpath "$file" 2>/dev/null || echo "$file")
                
                # Check if file exists (it should)
                if [ -e "$ABS_PATH" ]; then
                    echo "[bash-hook-wrapper] File exists, will be deleted: $ABS_PATH" >> "$LOG_FILE"
                    
                    # Base64 encode the path to avoid escaping issues
                    ABS_PATH_B64=$(echo -n "$ABS_PATH" | base64)
                    
                    # Send notification to Neovim using nvr-proxy
                    echo "[bash-hook-wrapper] Calling nvr-proxy with base64 encoded path" >> "$LOG_FILE"
                    TARGET_FILE="$ABS_PATH" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').track_deleted_file_b64('$ABS_PATH_B64')\")" 2>&1 | tee -a "$LOG_FILE"
                    echo "[bash-hook-wrapper] nvr-proxy exit code: $?" >> "$LOG_FILE"
                else
                    echo "[bash-hook-wrapper] File doesn't exist: $ABS_PATH" >> "$LOG_FILE"
                fi
            fi
        done <<< "$FILES_OUTPUT"
    else
        echo "[bash-hook-wrapper] No files found for deletion" >> "$LOG_FILE"
    fi
fi

# Always allow the command to proceed
exit 0