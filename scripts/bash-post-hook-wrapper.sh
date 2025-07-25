#!/bin/bash

# Post-hook wrapper for bash commands
# This script is called by Claude Code after executing bash commands
# It verifies rm commands actually deleted the files

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log file location
LOG_FILE="${HOME}/.local/share/nvim/nvim-claude-hooks.log"

# Log that the hook was called
echo "[bash-post-hook-wrapper] Hook called at $(date)" >> "$LOG_FILE"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Extract the command from the JSON
COMMAND=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty')

# Extract the exit code from the response
EXIT_CODE=$(echo "$JSON_INPUT" | jq -r '.tool_response.exit_code // empty')

# Log for debugging
echo "[bash-post-hook-wrapper] Command: $COMMAND" >> "$LOG_FILE"
echo "[bash-post-hook-wrapper] Exit code: $EXIT_CODE" >> "$LOG_FILE"

# Check if it's an rm command
if [[ "$COMMAND" =~ ^rm[[:space:]] ]]; then
    echo "[bash-post-hook-wrapper] Detected rm command, verifying deletions" >> "$LOG_FILE"
    
    # Use ls to check which files still exist
    # Replace 'rm' with 'ls -d' to check file existence
    LS_COMMAND=$(echo "$COMMAND" | sed 's/^rm /ls -d /')
    
    echo "[bash-post-hook-wrapper] Running ls command to check remaining files: $LS_COMMAND" >> "$LOG_FILE"
    
    # Execute the ls command to see which files still exist
    # Redirect stderr to /dev/null as we expect some files to not exist
    FILES_OUTPUT=$(eval "$LS_COMMAND" 2>/dev/null)
    
    if [ -n "$FILES_OUTPUT" ]; then
        echo "[bash-post-hook-wrapper] Some files were not deleted, untracking them" >> "$LOG_FILE"
        
        # Process each file that still exists (deletion failed)
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                # Get absolute path
                ABS_PATH=$(realpath "$file" 2>/dev/null || echo "$file")
                
                # Check if file still exists
                if [ -e "$ABS_PATH" ]; then
                    echo "[bash-post-hook-wrapper] File still exists, untracking: $ABS_PATH" >> "$LOG_FILE"
                    
                    # Escape the path for Lua
                    ABS_PATH_ESCAPED=$(echo "$ABS_PATH" | sed "s/\\\\/\\\\\\\\/g" | sed "s/'/\\\\'/g")
                    
                    # Call untrack function in Neovim
                    echo "[bash-post-hook-wrapper] Calling nvr-proxy to untrack: $ABS_PATH_ESCAPED" >> "$LOG_FILE"
                    TARGET_FILE="$ABS_PATH" "$SCRIPT_DIR/nvr-proxy.sh" --remote-expr "luaeval(\"require('nvim-claude.hooks').untrack_failed_deletion('$ABS_PATH_ESCAPED')\")" 2>&1 | tee -a "$LOG_FILE"
                    echo "[bash-post-hook-wrapper] nvr-proxy exit code: $?" >> "$LOG_FILE"
                fi
            fi
        done <<< "$FILES_OUTPUT"
    else
        echo "[bash-post-hook-wrapper] All files successfully deleted" >> "$LOG_FILE"
    fi
fi

# Always allow the command to proceed
exit 0