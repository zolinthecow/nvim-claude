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
COMMAND=$(printf '%s' "$JSON_INPUT" | jq -r '.tool_input.command // empty')
COMMAND_CWD=$(printf '%s' "$JSON_INPUT" | jq -r '.cwd // empty')
if [ ! -d "$COMMAND_CWD" ]; then
    COMMAND_CWD="$(pwd)"
fi

# Log for debugging
log "[bash-hook-wrapper] Command: $COMMAND"

while IFS= read -r -d '' ABS_PATH; do
    if [ -e "$ABS_PATH" ] || [ -L "$ABS_PATH" ]; then
        log "[bash-hook-wrapper] File exists, will be deleted: $ABS_PATH"
        ABS_PATH_B64=$(printf '%s' "$ABS_PATH" | base64 | tr -d '\n')
        PLUGIN_ROOT="$(get_plugin_root)"
        TARGET_FILE="$ABS_PATH" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').track_deleted_file_b64('$ABS_PATH_B64')\")" 2>&1 | tee_to_log
        log "[bash-hook-wrapper] nvim-rpc exit code: $?"
    fi
done < <(python3 "$SCRIPT_DIR/rm-targets.py" "$COMMAND" "$COMMAND_CWD" 2>/dev/null)

# Always allow the command to proceed
exit 0
