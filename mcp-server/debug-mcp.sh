#!/bin/bash
# MCP Server Debug Script

echo "=== MCP Server Debug Information ==="
echo "Current directory: $(pwd)"
echo "Date: $(date)"
echo ""

# Check for nvim-server file in current project
echo "1. Checking for .nvim-claude/nvim-server in current directory:"
if [ -f ".nvim-claude/nvim-server" ]; then
    echo "   ✓ Found: $(cat .nvim-claude/nvim-server)"
else
    echo "   ✗ Not found"
fi
echo ""

# Check Python environment
echo "2. Python environment:"
VENV_PATH="$HOME/.local/share/nvim/nvim-claude/mcp-env"
if [ -d "$VENV_PATH" ]; then
    echo "   ✓ Virtual environment exists at: $VENV_PATH"
    if [ -f "$VENV_PATH/bin/python" ]; then
        echo "   ✓ Python executable found"
        "$VENV_PATH/bin/python" --version
    else
        echo "   ✗ Python executable not found"
    fi
else
    echo "   ✗ Virtual environment not found at: $VENV_PATH"
fi
echo ""

# Check MCP server script
echo "3. MCP server script:"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -f "$SCRIPT_DIR/nvim-lsp-server.py" ]; then
    echo "   ✓ Found at: $SCRIPT_DIR/nvim-lsp-server.py"
else
    echo "   ✗ Not found at: $SCRIPT_DIR/nvim-lsp-server.py"
fi
echo ""

# Check nvr installation
echo "4. Neovim remote (nvr):"
if command -v nvr &> /dev/null; then
    echo "   ✓ nvr is installed: $(which nvr)"
    nvr --version
else
    echo "   ✗ nvr is not installed"
fi
echo ""

# Test MCP server connection
echo "5. Testing MCP server startup:"
export NVIM_LSP_DEBUG=1
if [ -f "$VENV_PATH/bin/python" ] && [ -f "$SCRIPT_DIR/nvim-lsp-server.py" ]; then
    echo "   Running: $VENV_PATH/bin/python $SCRIPT_DIR/nvim-lsp-server.py"
    echo "   (Press Ctrl+C to stop)"
    echo ""
    echo "   === MCP Server Output ==="
    "$VENV_PATH/bin/python" "$SCRIPT_DIR/nvim-lsp-server.py" 2>&1
else
    echo "   ✗ Cannot test - missing Python or server script"
fi