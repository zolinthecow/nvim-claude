#!/bin/bash
# Stop hook validator for nvim-claude
# Checks for lint errors in edited files and blocks completion if found

# Read JSON input from stdin
INPUT=$(cat)

# Find the Neovim server address
# First try project-specific location
if [ -f ".nvim-claude/nvim-server" ]; then
    SERVER_ADDR=$(cat .nvim-claude/nvim-server | tr -d '\n')
elif [ -f "$HOME/.local/share/nvim/nvim-claude/nvim-server" ]; then
    # Fallback to global location
    SERVER_ADDR=$(cat "$HOME/.local/share/nvim/nvim-claude/nvim-server" | tr -d '\n')
else
    # If no server address found, allow completion
    echo '{"continue": true}'
    exit 0
fi

# Get diagnostic counts from Neovim using the correct server
# Use v:lua to call Lua function
LUA_EXPR='v:lua.require("nvim-claude.hooks").get_session_diagnostic_counts()'
DIAGNOSTIC_JSON=$(nvr --servername "$SERVER_ADDR" --remote-expr "$LUA_EXPR" 2>&1)

# Debug: Log what we got from nvr
echo "DEBUG: nvr returned: $DIAGNOSTIC_JSON" >> /tmp/stop-hook-debug.log

# Check if nvr command succeeded or returned empty
if [ $? -ne 0 ] || [ -z "$DIAGNOSTIC_JSON" ]; then
    # If nvr fails, allow completion to avoid blocking Claude
    echo '{"continue": true}'
    exit 0
fi

# Parse diagnostic counts - handle potential nvr output quirks
# nvr might return the JSON with extra characters, so we extract just the JSON part
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