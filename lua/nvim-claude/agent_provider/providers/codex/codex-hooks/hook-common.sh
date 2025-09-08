#!/usr/bin/env bash

# Common utilities for provider hooks

LOG_FILE=""

_set_log_from_path() {
  local path="$1"; if [ -z "$path" ]; then path="$(pwd)"; fi
  local dir="$path"; if [ -f "$path" ]; then dir="$(dirname "$path")"; fi
  local root
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$root" ]; then root="$dir"; fi
  if command -v realpath >/dev/null 2>&1; then root="$(realpath "$root" 2>/dev/null || echo "$root")"; fi
  local key_hash
  if command -v shasum >/dev/null 2>&1; then key_hash=$(echo -n "$root" | shasum -a 256 | cut -d' ' -f1)
  else key_hash=$(echo -n "$root" | sha256sum | cut -d' ' -f1)
  fi
  local short_hash=${key_hash:0:8}
  local log_dir="$HOME/.local/share/nvim/nvim-claude/logs/$short_hash"
  mkdir -p "$log_dir" 2>/dev/null || true
  LOG_FILE="$log_dir/debug.log"
}

set_project_log_from_json() {
  local json="$1"
  local cwd=$(echo "$json" | jq -r '.cwd // empty' 2>/dev/null)
  if [ -n "$cwd" ]; then _set_log_from_path "$cwd"; return; fi
  _set_log_from_path "$(pwd)"
}

log() {
  if [ -n "$LOG_FILE" ]; then echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; fi
}

tee_to_log() {
  if [ -n "$LOG_FILE" ]; then tee -a "$LOG_FILE"; else cat > /dev/null; fi
}

get_plugin_root() {
  local here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local candidate="$here/../../../../../../"
  candidate="$(cd "$candidate" 2>/dev/null && pwd || echo '')"
  if [ -n "$candidate" ] && [ -f "$candidate/rpc/nvim-rpc.sh" ]; then echo "$candidate"; return; fi
  local dir="$here"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/rpc/nvim-rpc.sh" ]; then echo "$dir"; return; fi
    dir="$(dirname "$dir")"
  done
  echo "$here"
}

