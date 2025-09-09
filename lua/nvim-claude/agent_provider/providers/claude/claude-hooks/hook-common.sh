#!/usr/bin/env bash

#!/usr/bin/env bash

# Common utilities for nvim-claude hooks

# No default global log file. Will be set per-project.
LOG_FILE=""

# Compute project-specific debug log path from a working path (cwd or file path)
_set_log_from_path() {
    local path="$1"
    if [ -z "$path" ]; then path="$(pwd)"; fi

    # Resolve project root: prefer git toplevel; fallback to directory of path or cwd
    local dir="$path"
    if [ -f "$path" ]; then dir="$(dirname "$path")"; fi
    local root
    root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$root" ]; then root="$dir"; fi

    # Normalize path (best effort)
    if command -v realpath >/dev/null 2>&1; then
        root="$(realpath "$root" 2>/dev/null || echo "$root")"
    fi

    # Hash the project key (path) to short id
    local key_hash short_hash log_dir
    if command -v shasum >/dev/null 2>&1; then
        key_hash=$(echo -n "$root" | shasum -a 256 | cut -d' ' -f1)
    elif command -v sha256sum >/dev/null 2>&1; then
        key_hash=$(echo -n "$root" | sha256sum | cut -d' ' -f1)
    else
        # Fallback: use plain path with unsafe chars replaced
        key_hash=$(echo -n "$root" | tr '/\n\r\t ' '-' )
    fi
    short_hash=${key_hash:0:8}
    log_dir="$HOME/.local/share/nvim/nvim-claude/logs/$short_hash"
    mkdir -p "$log_dir" 2>/dev/null || true
    LOG_FILE="$log_dir/debug.log"
}

# Set project-specific log from a JSON payload that may contain cwd or file paths
set_project_log_from_json() {
    local json="$1"
    if [ -z "$json" ]; then
        _set_log_from_path "$(pwd)"
        return
    fi
    # Order of preference: cwd -> tool_input.file_path -> tool_response.filePath
    local cwd
    cwd=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)
    if [ -n "$cwd" ]; then
        _set_log_from_path "$cwd"
        return
    fi
    local file1
    file1=$(echo "$json" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -n "$file1" ]; then
        _set_log_from_path "$file1"
        return
    fi
    local file2
    file2=$(echo "$json" | jq -r '.tool_response.filePath // empty' 2>/dev/null)
    if [ -n "$file2" ]; then
        _set_log_from_path "$file2"
        return
    fi
    _set_log_from_path "$(pwd)"
}

log() {
    if [ -n "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    fi
}

# Helper used in pipelines: write stdin to project log if set; otherwise discard
tee_to_log() {
    if [ -n "$LOG_FILE" ]; then
        tee -a "$LOG_FILE"
    else
        cat > /dev/null
    fi
}

escape_for_lua() {
    echo "$1" | sed "s/'/\\\\'/g"
}

# Compute plugin root path relative to this script location
# New layout: lua/nvim-claude/agent_provider/providers/claude/claude-hooks/
get_plugin_root() {
  local here="$SCRIPT_DIR"
  local candidate="$here/../../../../../../"
  candidate="$(cd "$candidate" 2>/dev/null && pwd || echo '')"
  if [ -n "$candidate" ] && [ -f "$candidate/rpc/nvim-rpc.sh" ]; then
    echo "$candidate"
    return
  fi
  # Fallback: ascend until rpc/nvim-rpc.sh found
  local dir="$here"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/rpc/nvim-rpc.sh" ]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
  echo "$here"
}
