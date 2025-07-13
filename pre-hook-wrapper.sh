#!/bin/bash
# Pre-hook wrapper for nvim-claude
# This script is called by Claude Code before file editing tools

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Call the nvr-proxy to execute the pre-hook
"$SCRIPT_DIR/nvr-proxy.sh" --remote-expr 'luaeval("require('"'"'nvim-claude.hooks'"'"').pre_tool_use_hook()")'

# Return the exit code from nvr
exit $?