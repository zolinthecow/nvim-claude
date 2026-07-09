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
COMMAND=$(printf '%s' "$JSON_INPUT" | jq -r '.tool_input.command // empty')
COMMAND_CWD=$(printf '%s' "$JSON_INPUT" | jq -r '.cwd // empty')
if [ ! -d "$COMMAND_CWD" ]; then
    COMMAND_CWD="$(pwd)"
fi

# Extract the exit code from the response
EXIT_CODE=$(echo "$JSON_INPUT" | jq -r '.tool_response.exit_code // empty')

# Log for debugging
log "[bash-post-hook-wrapper] Command: $COMMAND"
log "[bash-post-hook-wrapper] Exit code: $EXIT_CODE"

while IFS= read -r -d '' ABS_PATH; do
    if [ -e "$ABS_PATH" ] || [ -L "$ABS_PATH" ]; then
        log "[bash-post-hook-wrapper] File still exists, untracking: $ABS_PATH"
        ABS_PATH_B64=$(printf '%s' "$ABS_PATH" | base64 | tr -d '\n')
        PLUGIN_ROOT="$(get_plugin_root)"
        TARGET_FILE="$ABS_PATH" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').untrack_failed_deletion_b64('$ABS_PATH_B64')\")" 2>&1 | tee_to_log
        log "[bash-post-hook-wrapper] nvim-rpc exit code: $?"
    fi
done < <(python3 "$SCRIPT_DIR/rm-targets.py" "$COMMAND" "$COMMAND_CWD" 2>/dev/null)

# Always allow the command to proceed
exit 0
