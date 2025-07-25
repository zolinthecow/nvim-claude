#!/bin/bash

# Bash hook wrapper for nvim-claude
# This script is called by Claude Code when executing bash commands
# It detects rm commands and notifies Neovim about deleted files

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load common functions
source "$SCRIPT_DIR/hook-common.sh"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Extract the command from the JSON
COMMAND=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty')

# Log for debugging
echo "[bash-hook-wrapper] Command: $COMMAND" >> "$LOG_FILE"

# Check if it's an rm command
if [[ "$COMMAND" =~ ^rm[[:space:]] ]]; then
    echo "[bash-hook-wrapper] Detected rm command" >> "$LOG_FILE"
    
    # Parse the rm command to extract file paths
    # This is a simple implementation - we'll improve it later
    
    # Remove 'rm' and any flags (anything starting with -)
    FILES_PART=$(echo "$COMMAND" | sed 's/^rm\s*//' | sed 's/\s*-[^ ]*//g')
    
    # Split into individual files (this is simplified - doesn't handle quoted paths well)
    IFS=' ' read -ra FILES <<< "$FILES_PART"
    
    # For each file, check if it exists before deletion
    for file in "${FILES[@]}"; do
        if [ -n "$file" ] && [ "$file" != "" ]; then
            # Get absolute path
            ABS_PATH=$(realpath "$file" 2>/dev/null || echo "$file")
            
            # Check if file exists (it should, since this is pre-hook)
            if [ -e "$ABS_PATH" ]; then
                echo "[bash-hook-wrapper] File exists, will be deleted: $ABS_PATH" >> "$LOG_FILE"
                
                # Send notification to Neovim
                send_to_nvim "lua require('nvim-claude.hooks').track_deleted_file('$ABS_PATH')"
            else
                echo "[bash-hook-wrapper] File doesn't exist: $ABS_PATH" >> "$LOG_FILE"
            fi
        fi
    done
fi

# Always allow the command to proceed
exit 0