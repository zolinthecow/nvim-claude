#!/bin/bash

# Post-hook wrapper for bash commands
# This script is called by Claude Code after executing bash commands
# It verifies rm commands actually deleted the files

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common helpers
source "$SCRIPT_DIR/hook-common.sh"

# Read the JSON input from stdin
JSON_INPUT=$(cat)

# Switch logging to project-specific debug log
set_project_log_from_json "$JSON_INPUT"

# Log that the hook was called
log "[bash-post-hook-wrapper] Hook called"

# Extract the command from the JSON
COMMAND=$(echo "$JSON_INPUT" | jq -r '.tool_input.command // empty')

# Extract the exit code from the response
EXIT_CODE=$(echo "$JSON_INPUT" | jq -r '.tool_response.exit_code // empty')

# Log for debugging
log "[bash-post-hook-wrapper] Command: $COMMAND"
log "[bash-post-hook-wrapper] Exit code: $EXIT_CODE"

# Check if it's an rm command
if [[ "$COMMAND" =~ ^rm[[:space:]] ]]; then
    log "[bash-post-hook-wrapper] Detected rm command, verifying deletions"
    
    # Use ls to check which files still exist
    # Replace 'rm' with 'ls -d' to check file existence
    LS_COMMAND=$(echo "$COMMAND" | sed 's/^rm /ls -d /')
    
    log "[bash-post-hook-wrapper] Running ls command to check remaining files: $LS_COMMAND"
    
    # Execute the ls command to see which files still exist
    # Redirect stderr to /dev/null as we expect some files to not exist
    FILES_OUTPUT=$(eval "$LS_COMMAND" 2>/dev/null)
    
    if [ -n "$FILES_OUTPUT" ]; then
        log "[bash-post-hook-wrapper] Some files were not deleted, untracking them"
        
        # Process each file that still exists (deletion failed)
        while IFS= read -r file; do
            if [ -n "$file" ]; then
                # Get absolute path
                ABS_PATH=$(realpath "$file" 2>/dev/null || echo "$file")
                
                # Check if file still exists
                if [ -e "$ABS_PATH" ]; then
                    log "[bash-post-hook-wrapper] File still exists, untracking: $ABS_PATH"
                    
                    # Base64 encode the path to avoid escaping issues
                    ABS_PATH_B64=$(echo -n "$ABS_PATH" | base64)
                    
                    # Call untrack function in Neovim
                    log "[bash-post-hook-wrapper] Calling nvim-rpc to untrack with base64 encoded path"
                    PLUGIN_ROOT="$(get_plugin_root)"
                    TARGET_FILE="$ABS_PATH" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').untrack_failed_deletion_b64('$ABS_PATH_B64')\")" 2>&1 | tee_to_log
                    log "[bash-post-hook-wrapper] nvim-rpc exit code: $?"
                fi
            fi
        done <<< "$FILES_OUTPUT"
    else
        log "[bash-post-hook-wrapper] All files successfully deleted"
    fi
fi

# Always allow the command to proceed
exit 0
