#!/bin/bash
# This script acts as a proxy to find the most recently used Neovim server
# and forward commands to it via nvr (neovim-remote)

echo "[$(date)] nvr-proxy called with args: $@" >> /tmp/nvr-proxy-debug.log

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
PROJECT_ROOT=$(find_project_root)
if [ -z "$PROJECT_ROOT" ]; then
    echo "Error: Not in a git repository" >&2
    exit 1
fi

# Look for a server file - first in project root, then in script directory as fallback
SERVER_FILE="$PROJECT_ROOT/.nvim-server"
echo "[$(date)] Looking for server file: $SERVER_FILE" >> /tmp/nvr-proxy-debug.log
if [ -f "$SERVER_FILE" ]; then
    NVIM_SERVER=$(cat "$SERVER_FILE")
    echo "[$(date)] Found server: $NVIM_SERVER" >> /tmp/nvr-proxy-debug.log
    if [ -n "$NVIM_SERVER" ] && [ -e "$NVIM_SERVER" ]; then
        echo "[$(date)] Running: nvr --servername $NVIM_SERVER $@" >> /tmp/nvr-proxy-debug.log
        nvr --servername "$NVIM_SERVER" "$@"
        exit $?
    else
        echo "[$(date)] Server socket not found or empty: $NVIM_SERVER" >> /tmp/nvr-proxy-debug.log
    fi
else
    echo "[$(date)] No server file found at $SERVER_FILE" >> /tmp/nvr-proxy-debug.log
    # Fallback: check script directory (useful for submodules when .nvim-server exists there)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SERVER_FILE="$SCRIPT_DIR/.nvim-server"
    echo "[$(date)] Fallback: Looking for server file: $SERVER_FILE" >> /tmp/nvr-proxy-debug.log
    if [ -f "$SERVER_FILE" ]; then
        NVIM_SERVER=$(cat "$SERVER_FILE")
        echo "[$(date)] Found server: $NVIM_SERVER" >> /tmp/nvr-proxy-debug.log
        if [ -n "$NVIM_SERVER" ] && [ -e "$NVIM_SERVER" ]; then
            echo "[$(date)] Running: nvr --servername $NVIM_SERVER $@" >> /tmp/nvr-proxy-debug.log
            nvr --servername "$NVIM_SERVER" "$@"
            exit $?
        fi
    fi
fi

# Fallback: Find the most recent Neovim server in temp directories
NVIM_SERVER=$(find /var/folders /tmp -name "nvim.*.0" -type s 2>/dev/null | head -1)
if [ -n "$NVIM_SERVER" ]; then
    nvr --servername "$NVIM_SERVER" "$@"
else
    echo "Error: No Neovim server found" >&2
    exit 1
fi