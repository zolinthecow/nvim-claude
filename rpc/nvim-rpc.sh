#!/bin/bash
# Wrapper script to run nvim_rpc.py with the correct Python environment

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

resolve_rpc_env() {
    local candidates=()
    if [ -n "$NVIM_CLAUDE_RPC_ENV" ]; then
        candidates+=("$NVIM_CLAUDE_RPC_ENV")
    fi
    if [ -n "$XDG_DATA_HOME" ]; then
        candidates+=("$XDG_DATA_HOME/nvim/nvim-claude/rpc-env")
    fi
    if [ -n "$HOME" ]; then
        candidates+=("$HOME/.local/share/nvim/nvim-claude/rpc-env")
        candidates+=("$HOME/Library/Application Support/nvim/nvim-claude/rpc-env")
    fi
    local user_home
    user_home="$(eval echo "~$(id -un)")"
    if [ -n "$user_home" ] && [ "$user_home" != "~$(id -un)" ]; then
        candidates+=("$user_home/.local/share/nvim/nvim-claude/rpc-env")
        candidates+=("$user_home/Library/Application Support/nvim/nvim-claude/rpc-env")
    fi
    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "${candidates[0]}"
        return 0
    fi
    return 1
}

# Path to the RPC virtual environment
RPC_VENV_PATH="$(resolve_rpc_env)"
if [ -z "$RPC_VENV_PATH" ]; then
    echo "Error: Unable to determine RPC virtual environment path. Set NVIM_CLAUDE_RPC_ENV." >&2
    exit 1
fi

# Try to auto-install if missing
if [ ! -d "$RPC_VENV_PATH" ]; then
    INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
    if [ -f "$INSTALL_SCRIPT" ]; then
        NVIM_CLAUDE_RPC_ENV="$RPC_VENV_PATH" "$INSTALL_SCRIPT"
    fi
fi

# Check if the virtual environment exists
if [ ! -d "$RPC_VENV_PATH" ]; then
    echo "Error: RPC virtual environment not found at $RPC_VENV_PATH. Run :ClaudeInstallRPC in Neovim." >&2
    exit 1
fi

# Check if pynvim is installed
if [ ! -f "$RPC_VENV_PATH/bin/python" ]; then
    echo "Error: Python not found in RPC environment at $RPC_VENV_PATH. Run :ClaudeInstallRPC in Neovim." >&2
    exit 1
fi

# Pass through TARGET_FILE environment variable and all arguments
exec "$RPC_VENV_PATH/bin/python" "$SCRIPT_DIR/nvim_rpc.py" "$@"

