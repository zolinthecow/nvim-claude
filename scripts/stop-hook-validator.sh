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

# Find any file in the current project to use as TARGET_FILE
# This helps nvr-proxy find the correct Neovim instance for this project
if [ -d "$CWD" ]; then
    TARGET_FILE=$(find "$CWD" -type f -name "*.md" -o -name "*.txt" -o -name "*.lua" -o -name "*.js" 2>/dev/null | head -1)
    if [ -z "$TARGET_FILE" ]; then
        TARGET_FILE=$(find "$CWD" -type f 2>/dev/null | head -1)
    fi
fi

# If still no file found, use the CWD itself
if [ -z "$TARGET_FILE" ]; then
    TARGET_FILE="$CWD"
fi

# Get diagnostic counts from Neovim using nvim-rpc
# This will find the correct server for this project
DIAGNOSTIC_JSON=$(TARGET_FILE="$TARGET_FILE" "$SCRIPT_DIR/nvim-rpc.sh" --remote-expr 'v:lua.require("nvim-claude.hooks").get_session_diagnostic_counts()' 2>&1)

# Debug: Log what we got from nvim-rpc
echo "DEBUG: nvim-rpc returned: $DIAGNOSTIC_JSON" >> /tmp/stop-hook-debug.log

# Check if nvim-rpc command succeeded or returned empty
if [ $? -ne 0 ] || [ -z "$DIAGNOSTIC_JSON" ]; then
    # If nvim-rpc fails, allow completion to avoid blocking Claude
    echo '{"continue": true}'
    exit 0
fi

# Parse diagnostic counts - handle potential output quirks
# nvim-rpc might return the JSON with extra characters, so we extract just the JSON part
CLEAN_JSON=$(echo "$DIAGNOSTIC_JSON" | grep -o '{.*}' | head -1)
if [ -z "$CLEAN_JSON" ]; then
    # No valid JSON found, allow completion
    echo '{"continue": true}'
    exit 0
fi

ERROR_COUNT=$(echo "$CLEAN_JSON" | jq -r '.errors // 0')
WARNING_COUNT=$(echo "$CLEAN_JSON" | jq -r '.warnings // 0')
TOTAL_COUNT=$((ERROR_COUNT + WARNING_COUNT))

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
    echo '{"continue": true}'
fi