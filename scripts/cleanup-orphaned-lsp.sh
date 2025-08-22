#!/bin/bash
# Cleanup script for orphaned LSP servers and headless Neovim instances

echo "[$(date)] Starting cleanup of orphaned processes..."

# Get current project hash for targeted cleanup
CWD=$(pwd)
PROJECT_HASH=$(echo -n "$CWD" | shasum -a 256 | cut -c1-8)
PROJECT_SOCKET="/tmp/nvim-claude-headless-${PROJECT_HASH}.sock"

# Kill orphaned headless Neovim instances for THIS project only (keep only the most recent)
HEADLESS_PIDS=$(pgrep -f "nvim --headless --listen $PROJECT_SOCKET" | sort -n)
if [ ! -z "$HEADLESS_PIDS" ]; then
    HEADLESS_COUNT=$(echo "$HEADLESS_PIDS" | wc -l)
    echo "  Found $HEADLESS_COUNT headless instances for current project"
    
    if [ "$HEADLESS_COUNT" -gt 1 ]; then
        # Keep the last one (most recent), kill the rest
        echo "$HEADLESS_PIDS" | head -n $((HEADLESS_COUNT - 1)) | while read pid; do
            if [ ! -z "$pid" ]; then
                echo "  Killing orphaned headless Neovim for this project: PID $pid"
                kill -TERM "$pid" 2>/dev/null
            fi
        done
    fi
else
    echo "  No headless instances found for current project"
fi

# Clean up stale socket files for THIS project
PROJECT_LOCK="/tmp/nvim-claude-headless-${PROJECT_HASH}.lock"

if [ -e "$PROJECT_SOCKET" ]; then
    # Check if socket is actually in use
    if ! lsof "$PROJECT_SOCKET" >/dev/null 2>&1; then
        echo "  Removing stale socket for this project: $PROJECT_SOCKET"
        rm -f "$PROJECT_SOCKET"
    fi
fi

# Clean up stale lock files for THIS project
if [ -e "$PROJECT_LOCK" ]; then
    # Check if lock is older than 10 minutes
    if [ "$(find "$PROJECT_LOCK" -mmin +10 2>/dev/null)" ]; then
        echo "  Removing stale lock for this project: $PROJECT_LOCK"
        rm -f "$PROJECT_LOCK"
    fi
fi

# Clean up ShaDa temp files
SHADA_DIR="$HOME/.local/state/nvim/shada"
if [ -d "$SHADA_DIR" ]; then
    TEMP_COUNT=$(find "$SHADA_DIR" -name "*.tmp.*" 2>/dev/null | wc -l)
    if [ "$TEMP_COUNT" -gt 0 ]; then
        echo "  Cleaning up $TEMP_COUNT ShaDa temp files"
        find "$SHADA_DIR" -name "*.tmp.*" -delete 2>/dev/null
    fi
fi

echo "[$(date)] Cleanup complete"