#!/bin/bash
# Wrapper script to run nvim_rpc.py with the correct Python environment

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Path to the RPC virtual environment
RPC_VENV_PATH="$HOME/.local/share/nvim/nvim-claude/rpc-env"

# Check if the virtual environment exists
if [ ! -d "$RPC_VENV_PATH" ]; then
    echo "Error: RPC virtual environment not found. Run :ClaudeInstallMCP in Neovim." >&2
    exit 1
fi

# Check if pynvim is installed
if [ ! -f "$RPC_VENV_PATH/bin/python" ]; then
    echo "Error: Python not found in RPC environment." >&2
    exit 1
fi

# Pass through TARGET_FILE environment variable and all arguments
exec "$RPC_VENV_PATH/bin/python" "$SCRIPT_DIR/nvim_rpc.py" "$@"