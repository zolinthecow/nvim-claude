#!/bin/bash
# Stop hook validator for nvim-claude
# Checks for lint errors in edited files and blocks completion if found

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get project-specific debug log file
get_debug_log_file() {
    local project_path="$1"
    if [ -n "$project_path" ]; then
        # Use same hashing as logger.lua - project-specific folder structure
        local key_hash=$(echo -n "$project_path" | shasum -a 256 | cut -d' ' -f1)
        local short_hash=${key_hash:0:8}
        local log_dir="$HOME/.local/share/nvim/nvim-claude/logs/$short_hash"
        mkdir -p "$log_dir"
        echo "$log_dir/stop-hook-debug.log"
    else
        echo "/tmp/stop-hook-debug.log"  # fallback
    fi
}

# Read JSON input from stdin
INPUT=$(cat)

# Get the working directory from JSON, then resolve to git root for state lookups
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then CWD=$(pwd); fi

# Resolve project root (git toplevel if available)
PROJECT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$PROJECT_ROOT" ]; then PROJECT_ROOT="$CWD"; fi

# Change to the project root to ensure correct project state loading
cd "$PROJECT_ROOT" 2>/dev/null || true

# Get project-specific debug log file
DEBUG_LOG=$(get_debug_log_file "$PROJECT_ROOT")

# Get the path to the MCP environment Python
MCP_PYTHON="$HOME/.local/share/nvim/nvim-claude/mcp-env/bin/python"

# Check if the MCP environment exists
if [ ! -f "$MCP_PYTHON" ]; then
    echo "# ERROR: MCP environment not found at $MCP_PYTHON" >> "$DEBUG_LOG"
    # Allow completion if MCP not installed
    echo '{"decision": "approve"}'
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
    SESSION_FILES=$(cat "$STATE_FILE" | jq -r --arg cwd "$PROJECT_ROOT" '.[$cwd].session_edited_files // [] | .[]' 2>/dev/null)
    
    # Debug: Log the files we found
    echo "DEBUG: Found session files: $SESSION_FILES" >> "$DEBUG_LOG"
    
    if [ -z "$SESSION_FILES" ]; then
        echo "# INFO: No session edited files found for project $CWD" >> "$DEBUG_LOG"
        # No files edited, allow completion
        echo '{"decision": "allow"}'
        exit 0
    fi
    
    # Convert the list of files to an array for batching
    FILE_LIST=()
    while IFS= read -r file; do
        if [ -n "$file" ]; then
            FILE_LIST+=("$file")
        fi
    done <<< "$SESSION_FILES"
    
    # Process files in batches of 10 to avoid overwhelming MCP server
    TOTAL_ERRORS=0
    TOTAL_WARNINGS=0
    BATCH_SIZE=10
    
    if [ ${#FILE_LIST[@]} -gt 0 ]; then
        for ((i=0; i<${#FILE_LIST[@]}; i+=BATCH_SIZE)); do
            # Create batch arguments
            BATCH_ARGS=""
            for ((j=i; j<i+BATCH_SIZE && j<${#FILE_LIST[@]}; j++)); do
                BATCH_ARGS="$BATCH_ARGS \"${FILE_LIST[j]}\""
            done
            
            echo "DEBUG: Batch $((i/BATCH_SIZE + 1)): $MCP_PYTHON $SCRIPT_DIR/../rpc/check-diagnostics.py $BATCH_ARGS" >> "$DEBUG_LOG"
            BATCH_JSON=$(eval "$MCP_PYTHON" "$SCRIPT_DIR/../rpc/check-diagnostics.py" $BATCH_ARGS 2>/dev/null)
            echo "DEBUG: Batch result: $BATCH_JSON" >> "$DEBUG_LOG"
            
            # Parse batch results and add to totals
            BATCH_ERRORS=$(echo "$BATCH_JSON" | jq -r '.errors // 0')
            BATCH_WARNINGS=$(echo "$BATCH_JSON" | jq -r '.warnings // 0')
            TOTAL_ERRORS=$((TOTAL_ERRORS + BATCH_ERRORS))
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + BATCH_WARNINGS))
        done
        
        DIAGNOSTIC_JSON="{\"errors\":$TOTAL_ERRORS,\"warnings\":$TOTAL_WARNINGS}"
    else
        DIAGNOSTIC_JSON='{"errors":0,"warnings":0}'
    fi
else
    echo "# INFO: No project state file found" >> "$DEBUG_LOG"
    # No state file, allow completion
    echo '{"decision": "allow"}'
    exit 0
fi

# Debug: Log what we got from check-diagnostics.py
echo "DEBUG: check-diagnostics.py returned: $DIAGNOSTIC_JSON" >> "$DEBUG_LOG"

# Parse diagnostic counts
ERROR_COUNT=$(echo "$DIAGNOSTIC_JSON" | jq -r '.errors // 0')
WARNING_COUNT=$(echo "$DIAGNOSTIC_JSON" | jq -r '.warnings // 0')

# Clear session tracking regardless of outcome to prevent accumulation
# Find a file in the project to use as TARGET_FILE for nvim-rpc
TARGET_FILE=$(find "$CWD" -type f -name "*.md" -o -name "*.txt" -o -name "*.lua" -o -name "*.js" 2>/dev/null | head -1)
if [ -z "$TARGET_FILE" ]; then
    TARGET_FILE=$(find "$CWD" -type f 2>/dev/null | head -1)
fi
if [ -z "$TARGET_FILE" ]; then
    TARGET_FILE="$CWD"
fi

# Check if we should block - only block on errors, not warnings
if [ "$ERROR_COUNT" -gt 0 ]; then
    # Fetch detailed session diagnostics to include in the reason
    SESSION_JSON=$("$MCP_PYTHON" "$SCRIPT_DIR/../rpc/get-session-diagnostics.py" 2>/dev/null)
    # Build reason with full diagnostics JSON
    JSON_REASON=$(printf '%s' "$SESSION_JSON" | jq -Rs .)
    
    echo "# INFO: Blocking due to $ERROR_COUNT errors; preserving session_edited_files for visibility" >> "$DEBUG_LOG"
    # Do NOT clear session tracking on block, so users/tools can inspect diagnostics
    # It will be cleared on successful validation (allow path) below
    
    # Return block decision (no "continue" field); reason is a proper JSON string
    echo "{\"decision\":\"block\",\"reason\":$JSON_REASON}"
else
    # No errors found, allow completion (warnings are okay)
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo "# INFO: Found $WARNING_COUNT warnings but allowing completion" >> "$DEBUG_LOG"
    fi
    
    echo "# INFO: No errors found, clearing session tracking and allowing completion" >> "$DEBUG_LOG"
    # Clear session tracking on successful validation
    TARGET_FILE="$TARGET_FILE" "$SCRIPT_DIR/../rpc/nvim-rpc.sh" --remote-expr 'v:lua.require("nvim-claude.events").clear_turn_files()' >/dev/null 2>&1 || true
    
    echo '{"decision": "allow"}'
fi
