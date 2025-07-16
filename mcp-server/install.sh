#!/bin/bash
set -e

echo '🔧 Setting up nvim-claude MCP server...'

# Check dependencies
if ! command -v python3 &> /dev/null; then
    echo '❌ Error: Python 3 is required but not installed.'
    exit 1
fi

if ! command -v nvr &> /dev/null; then
    echo '❌ Error: nvr (neovim-remote) is required but not installed.'
    echo '   Install with: pip install neovim-remote'
    exit 1
fi

# Setup paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VENV_PATH="$HOME/.local/share/nvim/nvim-claude/mcp-env"

# Create virtual environment
echo '📦 Creating Python virtual environment...'
python3 -m venv "$VENV_PATH"

# Install MCP (try fastmcp first, fallback to mcp)
echo '📥 Installing MCP package...'
"$VENV_PATH/bin/pip" install --quiet --upgrade pip

if "$VENV_PATH/bin/pip" install --quiet fastmcp; then
    echo 'fastmcp' > "$SCRIPT_DIR/requirements.txt"
    echo '✨ Using FastMCP (recommended)'
else
    echo '⚠️  FastMCP not available, using standard mcp package'
    "$VENV_PATH/bin/pip" install --quiet mcp
    echo 'mcp' > "$SCRIPT_DIR/requirements.txt"
fi

echo '✅ MCP server installed successfully!'
echo ''
echo 'To add to Claude Code, run this in your project directory:'
echo "  claude mcp add nvim-lsp -s local $VENV_PATH/bin/python $SCRIPT_DIR/nvim-lsp-server.py"
echo ''
echo 'Note: Use -s local to make it available only in the current project.'
echo 'The MCP server will automatically connect to the Neovim instance for that project.'