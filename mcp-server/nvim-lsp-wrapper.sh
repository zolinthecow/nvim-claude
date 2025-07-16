#!/bin/bash
# MCP wrapper that connects to the current Neovim instance
# This allows the MCP server to work with changing Neovim server addresses

# Find the current Neovim server address
if [ -f ".nvim-claude/nvim-server" ]; then
    export NVIM_SERVER=$(cat .nvim-claude/nvim-server | tr -d '\n')
elif [ -f "$HOME/.local/share/nvim/nvim-claude/nvim-server" ]; then
    export NVIM_SERVER=$(cat "$HOME/.local/share/nvim/nvim-claude/nvim-server" | tr -d '\n')
else
    echo "Error: No Neovim server found. Please start Neovim first." >&2
    exit 1
fi

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Find the Python virtual environment
VENV_PATH="$HOME/.local/share/nvim/nvim-claude/mcp-env"
if [ ! -d "$VENV_PATH" ]; then
    echo "Error: MCP virtual environment not found. Run :ClaudeInstallMCP in Neovim." >&2
    exit 1
fi

# Run the MCP server with the current Neovim server address
exec "$VENV_PATH/bin/python" "$SCRIPT_DIR/nvim-lsp-server.py" "$@"