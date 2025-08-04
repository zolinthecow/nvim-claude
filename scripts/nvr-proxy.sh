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

# Generate the same hash as Neovim to find the server file
PROJECT_HASH=$(echo -n "$PROJECT_ROOT" | shasum -a 256 | cut -c1-8)
TEMP_DIR="${XDG_RUNTIME_DIR:-/tmp}"
SERVER_FILE="$TEMP_DIR/nvim-claude-$PROJECT_HASH-server"

# Look for server file in temp location
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
