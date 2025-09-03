#!/usr/bin/env bash

# Common utilities for nvim-claude hooks

# Log file location (project-scoped could be added later)
LOG_FILE="${HOME}/.local/share/nvim/nvim-claude-hooks.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

escape_for_lua() {
    echo "$1" | sed "s/'/\\\\'/g"
}

