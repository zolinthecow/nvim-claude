#!/bin/bash
# Stop hook validator for nvim-claude
# Checks for lint errors in edited files and blocks completion if found

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read JSON input from stdin
INPUT=$(cat)

# Get the current working directory from the JSON input
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
    CWD=$(pwd)
fi

# Change to the project directory to ensure correct project state loading
cd "$CWD" 2>/dev/null || true

# Get the path to the MCP environment Python
MCP_PYTHON="$HOME/.local/share/nvim/nvim-claude/mcp-env/bin/python"

# Check if the MCP environment exists
if [ ! -f "$MCP_PYTHON" ]; then
    echo "# ERROR: MCP environment not found at $MCP_PYTHON" >> /tmp/stop-hook-debug.log
    # Allow completion if MCP not installed
    echo '{"continue": true}'
    exit 0
fi

# Read session edited files from project state
# We'll get the list of files from the nvim-claude project state
PROJECT_STATE_DIR="$HOME/.local/share/nvim/nvim-claude/projects"
STATE_FILE="$PROJECT_STATE_DIR/state.json"

# Extract session edited files for this project
if [ -f "$STATE_FILE" ]; then
    # Use jq to extract session_edited_files for the current project
    # The state file uses project paths as keys
    SESSION_FILES=$(cat "$STATE_FILE" | jq -r --arg cwd "$CWD" '.[$cwd].session_edited_files // [] | .[]' 2>/dev/null)
    
    # Debug: Log the files we found
    echo "DEBUG: Found session files: $SESSION_FILES" >> /tmp/stop-hook-debug.log
    
    if [ -z "$SESSION_FILES" ]; then
        echo "# INFO: No session edited files found for project $CWD" >> /tmp/stop-hook-debug.log
        # No files edited, allow completion
        echo '{"continue": true}'
        exit 0
    fi
    
    # Convert the list of files to arguments for check-diagnostics.py
    # Each file needs to be an absolute path
    FILE_ARGS=""
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            FILE_ARGS="$FILE_ARGS \"$file\""
        fi
    done <<< "$SESSION_FILES"
    
    # Call check-diagnostics.py with the session files
    if [ -n "$FILE_ARGS" ]; then
        echo "DEBUG: Running command: $MCP_PYTHON $SCRIPT_DIR/check-diagnostics.py $FILE_ARGS" >> /tmp/stop-hook-debug.log
        DIAGNOSTIC_JSON=$(eval "$MCP_PYTHON" "$SCRIPT_DIR/check-diagnostics.py" $FILE_ARGS 2>/dev/null)
    else
        DIAGNOSTIC_JSON='{"errors":0,"warnings":0}'
    fi
else
    echo "# INFO: No project state file found" >> /tmp/stop-hook-debug.log
    # No state file, allow completion
    echo '{"continue": true}'
    exit 0
fi

# Debug: Log what we got from check-diagnostics.py
echo "DEBUG: check-diagnostics.py returned: $DIAGNOSTIC_JSON" >> /tmp/stop-hook-debug.log

# Parse diagnostic counts
ERROR_COUNT=$(echo "$DIAGNOSTIC_JSON" | jq -r '.errors // 0')
WARNING_COUNT=$(echo "$DIAGNOSTIC_JSON" | jq -r '.warnings // 0')

# Check if we should block - only block on errors, not warnings
if [ "$ERROR_COUNT" -gt 0 ]; then
    REASON="Found $ERROR_COUNT errors in edited files. "
    REASON="${REASON}Please fix these errors before completing. "
    REASON="${REASON}Use 'mcp__nvim-lsp__get_session_diagnostics' to see details."
    
    # Return block decision
    cat <<EOF
{
    "decision": "block",
    "reason": "$REASON"
}
EOF
else
    # No errors found, allow completion (warnings are okay)
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo "# INFO: Found $WARNING_COUNT warnings but allowing completion" >> /tmp/stop-hook-debug.log
    fi
    
    # Clear session files on successful validation
    # We need to call nvim-rpc to clear the session tracking
    # Find a file in the project to use as TARGET_FILE
    TARGET_FILE=$(find "$CWD" -type f -name "*.md" -o -name "*.txt" -o -name "*.lua" -o -name "*.js" 2>/dev/null | head -1)
    if [ -z "$TARGET_FILE" ]; then
        TARGET_FILE=$(find "$CWD" -type f 2>/dev/null | head -1)
    fi
    if [ -z "$TARGET_FILE" ]; then
        TARGET_FILE="$CWD"
    fi
    
    # Clear session tracking via nvim-rpc
    TARGET_FILE="$TARGET_FILE" "$SCRIPT_DIR/nvim-rpc.sh" --remote-expr 'v:lua.require("nvim-claude.hooks").reset_session_tracking()' 2>/dev/null || true
    
    echo '{"continue": true}'
fi