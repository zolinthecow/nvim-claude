#!/usr/bin/env bash

# Common utilities for nvim-claude hooks

# Log file location
LOG_FILE="${HOME}/.local/share/nvim/nvim-claude-hooks.log"

# Function to send commands to Neovim
send_to_nvim() {
    local lua_cmd="$1"
    
    # Log the command
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sending to nvim: $lua_cmd" >> "$LOG_FILE"
    
    # Try to send to Neovim using nvr
    if command -v nvr >/dev/null 2>&1; then
        nvr --nostart --remote-expr "$lua_cmd" 2>>"$LOG_FILE" || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to send command via nvr" >> "$LOG_FILE"
            return 1
        }
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] nvr not found" >> "$LOG_FILE"
        return 1
    fi
}

# Function to escape single quotes for Lua strings
escape_for_lua() {
    echo "$1" | sed "s/'/\\\\'/g"
}