#!/bin/bash
# Stop hook validator for nvim-claude
# Checks for lint errors in edited files and blocks completion if found

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities (per-project debug.log)
source "$SCRIPT_DIR/hook-common.sh"

# Read JSON input from stdin
INPUT=$(cat)

# Get the working directory from JSON, then resolve to git root for state lookups
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then CWD=$(pwd); fi

# Set project log from the JSON and derive project root
set_project_log_from_json "$INPUT"
PROJECT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$PROJECT_ROOT" ]; then PROJECT_ROOT="$CWD"; fi
cd "$PROJECT_ROOT" 2>/dev/null || true

# Normalize project root to match Neovim's vim.fn.resolve (helps with /private prefixes on macOS)
PROJECT_ROOT_KEY="$PROJECT_ROOT"
if command -v python3 >/dev/null 2>&1; then
  PROJECT_ROOT_KEY=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PROJECT_ROOT")
elif command -v realpath >/dev/null 2>&1; then
  PROJECT_ROOT_KEY=$(realpath "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")
fi


# Get the path to the MCP environment Python
MCP_PYTHON="$HOME/.local/share/nvim/nvim-claude/mcp-env/bin/python"

# Check if the MCP environment exists
if [ ! -f "$MCP_PYTHON" ]; then
    log "# ERROR: MCP environment not found at $MCP_PYTHON"
    # Approve completion if MCP not installed
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
    JQ_OUT=$(jq -r --arg cwd "$PROJECT_ROOT_KEY" '.[$cwd].session_edited_files // [] | .[]' "$STATE_FILE" 2>&1)
    if echo "$JQ_OUT" | grep -qi '^jq:'; then
        SESSION_FILES=""
    else
        SESSION_FILES="$JQ_OUT"
    fi
    
    if [ -z "$SESSION_FILES" ]; then
        log "# INFO: No session edited files found for project $PROJECT_ROOT_KEY"
        # No files edited, approve completion
        echo '{"decision": "approve"}'
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

            PLUGIN_ROOT="$(get_plugin_root)"
            BATCH_JSON=$(eval "$MCP_PYTHON" "$PLUGIN_ROOT/rpc/check-diagnostics.py" $BATCH_ARGS 2>/dev/null)

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
    log "# INFO: No project state file found"
    # No state file, approve completion
    echo '{"decision": "approve"}'
    exit 0
fi



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
    PLUGIN_ROOT="$(get_plugin_root)"
    SESSION_JSON=$("$MCP_PYTHON" "$PLUGIN_ROOT/rpc/get-session-diagnostics.py" 2>/dev/null)
    # Build reason with full diagnostics JSON
    JSON_REASON=$(printf '%s' "$SESSION_JSON" | jq -Rs .)
    
    log "# INFO: Blocking due to $ERROR_COUNT errors; preserving session_edited_files for visibility"
    # Do NOT clear session tracking on block, so users/tools can inspect diagnostics
    # It will be cleared on successful validation (approve path) below
    
    # Return block decision (no "continue" field); reason is a proper JSON string
    echo "{\"decision\":\"block\",\"reason\":$JSON_REASON}"
else
    # No errors found, approve completion (warnings are okay)
    if [ "$WARNING_COUNT" -gt 0 ]; then
        log "# INFO: Found $WARNING_COUNT warnings but approving completion"
    fi
    
    log "# INFO: No errors found, clearing session tracking and aproving completion"
    PRE_SESSION_COUNT=$(cat "$STATE_FILE" | jq -r --arg cwd "$PROJECT_ROOT_KEY" '(.[$cwd].session_edited_files // []) | length' 2>/dev/null)

    # Clear session tracking for the exact project using base64-encoded TARGET_FILE via adapter
    TARGET_FILE_B64=$(echo -n "$TARGET_FILE" | base64)
    PLUGIN_ROOT="$(get_plugin_root)"
    TARGET_FILE="$TARGET_FILE" "$PLUGIN_ROOT/rpc/nvim-rpc.sh" --remote-expr "luaeval(\"require('nvim-claude.events.adapter').clear_turn_files_for_path_b64('$TARGET_FILE_B64')\")" >/dev/null 2>&1 || true

    POST_SESSION_COUNT=$(cat "$STATE_FILE" | jq -r --arg cwd "$PROJECT_ROOT_KEY" '(.[$cwd].session_edited_files // []) | length' 2>/dev/null)
    
    echo '{"decision": "approve"}'
fi
