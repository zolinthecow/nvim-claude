#!/bin/bash

# Bash hook wrapper for nvim-claude
# This script is called by Claude Code when executing bash commands
# It detects rm commands and notifies Neovim about deleted files

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common helpers
source "$SCRIPT_DIR/hook-common.sh"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Switch logging to project-specific debug log
set_project_log_from_json "$JSON_INPUT"

# Log that the hook was called
log "[bash-hook-wrapper] Hook called"
log "[bash-hook-wrapper] Script dir: $SCRIPT_DIR"

# Extract the command from the JSON
COMMAND=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty')

# Log for debugging
log "[bash-hook-wrapper] Command: $COMMAND"

# Check if it's an rm command
if [[ "$COMMAND" =~ ^rm[[:space:]] ]]; then
    log "[bash-hook-wrapper] Detected rm command"
    
    # Use ls to get the actual files that rm would target
    # Replace 'rm' with 'ls -d' to get exact file list
    LS_COMMAND=$(echo "$COMMAND" | sed 's/^rm /ls -d /')
    
    log "[bash-hook-wrapper] Running ls command to find targets: $LS_COMMAND"
    
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
                    log "[bash-hook-wrapper] File exists, will be deleted: $ABS_PATH"
                    
                    # Base64 encode the path to avoid escaping issues
                    ABS_PATH_B64=$(echo -n "$ABS_PATH" | base64)
                    
                    # Send notification to Neovim using nvim-rpc
                    log "[bash-hook-wrapper] Calling nvim-rpc with base64 encoded path"
                    PLUGIN_ROOT="$(get_plugin_root)"
                    TARGET_FILE="$ABS_PATH" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').track_deleted_file_b64('$ABS_PATH_B64')\")" 2>&1 | tee_to_log
                    log "[bash-hook-wrapper] nvim-rpc exit code: $?"
                else
                    log "[bash-hook-wrapper] File doesn't exist: $ABS_PATH"
                fi
            fi
        done <<< "$FILES_OUTPUT"
    else
        log "[bash-hook-wrapper] No files found for deletion"
    fi
fi

# Always allow the command to proceed
exit 0
