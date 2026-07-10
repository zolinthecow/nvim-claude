#!/bin/bash
# Cleanup script for orphaned LSP servers and headless Neovim instances

echo "[$(date)] Starting cleanup of orphaned processes..."

# Get current project hash for targeted cleanup.
CWD=$(pwd)
PROJECT_HASH=$(echo -n "$CWD" | shasum -a 256 | cut -c1-8)
SOCKET_PREFIX="/tmp/nvim-claude-headless-${PROJECT_HASH}"

FOUND=0
shopt -s nullglob
for socket in "${SOCKET_PREFIX}"-*.sock; do
    FOUND=1
    owner_pid=${socket%.sock}
    owner_pid=${owner_pid##*-}
    case "$owner_pid" in
        *[!0-9]*|'') continue ;;
    esac

    if kill -0 "$owner_pid" 2>/dev/null; then
        echo "  Keeping socket owned by live MCP process $owner_pid"
        continue
    fi

    pgrep -f "nvim --headless --listen $socket" 2>/dev/null | while read -r pid; do
        [ -n "$pid" ] || continue
        echo "  Stopping orphaned headless Neovim: PID $pid"
        kill -TERM "$pid" 2>/dev/null || true
    done
    rm -f "$socket"
done

if [ "$FOUND" -eq 0 ]; then
    echo "  No headless instances found for current project"
fi

# Remove artifacts from the former shared-socket implementation only when no
# process has the legacy socket open.
LEGACY_SOCKET="${SOCKET_PREFIX}.sock"
LEGACY_LOCK="${SOCKET_PREFIX}.lock"
if [ -e "$LEGACY_SOCKET" ] && ! lsof "$LEGACY_SOCKET" >/dev/null 2>&1; then
    rm -f "$LEGACY_SOCKET"
fi
if [ -e "$LEGACY_LOCK" ] && [ "$(find "$LEGACY_LOCK" -mmin +10 2>/dev/null)" ]; then
    rm -f "$LEGACY_LOCK"
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
