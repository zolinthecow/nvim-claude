#!/bin/bash
# This script acts as a proxy to find the most recently used Neovim server
# and forward commands to it via nvr (neovim-remote)

# Function to find the current project root by looking for .git directory
find_project_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Get the project root
# If TARGET_FILE is provided, find its project root
if [ -n "$TARGET_FILE" ]; then
    FILE_DIR=$(dirname "$TARGET_FILE")
    PROJECT_ROOT=$(cd "$FILE_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$PROJECT_ROOT" ]; then
        PROJECT_ROOT=$(find_project_root)
    fi
else
    PROJECT_ROOT=$(find_project_root)
fi

if [ -z "$PROJECT_ROOT" ]; then
    echo "Error: Not in a git repository" >&2
    exit 1
fi

# Look for server file in .nvim-claude directory first, then old location as fallback
SERVER_FILE="$PROJECT_ROOT/.nvim-claude/nvim-server"
OLD_SERVER_FILE="$PROJECT_ROOT/.nvim-server"
if [ -f "$SERVER_FILE" ]; then
    NVIM_SERVER=$(cat "$SERVER_FILE")
    if [ -n "$NVIM_SERVER" ] && [ -e "$NVIM_SERVER" ]; then
        # Capture output and exit code
        OUTPUT=$(nvr --servername "$NVIM_SERVER" "$@" 2>&1)
        EXIT_CODE=$?
        # Pass through the output to stdout
        echo "$OUTPUT"
        exit $EXIT_CODE
    fi
else
    # Fallback: check script directory (useful for submodules)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SERVER_FILE="$SCRIPT_DIR/.nvim-claude/nvim-server"
    OLD_SERVER_FILE="$SCRIPT_DIR/.nvim-server"
    if [ -f "$SERVER_FILE" ]; then
        NVIM_SERVER=$(cat "$SERVER_FILE")
        if [ -n "$NVIM_SERVER" ] && [ -e "$NVIM_SERVER" ]; then
            # Capture output and exit code
            OUTPUT=$(nvr --servername "$NVIM_SERVER" "$@" 2>&1)
            EXIT_CODE=$?
            # Pass through the output to stdout
            echo "$OUTPUT"
            exit $EXIT_CODE
        fi
    elif [ -f "$OLD_SERVER_FILE" ]; then
        # Try old location as fallback
        NVIM_SERVER=$(cat "$OLD_SERVER_FILE")
        if [ -n "$NVIM_SERVER" ] && [ -e "$NVIM_SERVER" ]; then
            # Capture output and exit code
            OUTPUT=$(nvr --servername "$NVIM_SERVER" "$@" 2>&1)
            EXIT_CODE=$?
            # Pass through the output to stdout
            echo "$OUTPUT"
            exit $EXIT_CODE
        fi
    fi
fi

# Fallback: Find the most recent Neovim server in temp directories
NVIM_SERVER=$(find /var/folders /tmp -name "nvim.*.0" -type s 2>/dev/null | head -1)
if [ -n "$NVIM_SERVER" ]; then
    OUTPUT=$(nvr --servername "$NVIM_SERVER" "$@" 2>&1)
    EXIT_CODE=$?
    echo "$OUTPUT"
    exit $EXIT_CODE
else
    echo "Error: No Neovim server found" >&2
    exit 1
fi
