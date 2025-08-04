#!/bin/bash
set -e

echo '🔧 Setting up nvim-claude MCP server...'

# Function to check Python version
check_python_version() {
    local python_cmd=$1
    if command -v "$python_cmd" &> /dev/null; then
        local version=$("$python_cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        local major=$(echo $version | cut -d. -f1)
        local minor=$(echo $version | cut -d. -f2)
        if [[ $major -gt 3 ]] || [[ $major -eq 3 && $minor -ge 10 ]]; then
            echo "$python_cmd"
            return 0
        fi
    fi
    return 1
}

# Find suitable Python (>= 3.10)
PYTHON_CMD=""
for cmd in python3.13 python3.12 python3.11 python3.10 python3 python; do
    if check_python_version "$cmd"; then
        PYTHON_CMD="$cmd"
        break
    fi
done

if [[ -z "$PYTHON_CMD" ]]; then
    echo '❌ Error: Python 3.10 or higher is required for fastmcp.'
    echo '   Your Python versions:'
    for cmd in python3 python; do
        if command -v "$cmd" &> /dev/null; then
            echo "   $cmd: $("$cmd" --version 2>&1)"
        fi
    done
    echo ''
    echo '   Please install Python 3.10+ using one of these methods:'
    echo '   • macOS: brew install python@3.11'
    echo '   • Ubuntu/Debian: sudo apt install python3.11'
    echo '   • pyenv: pyenv install 3.11.0'
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_CMD" --version 2>&1 | cut -d' ' -f2)
echo "✅ Found suitable Python: $PYTHON_CMD (version $PYTHON_VERSION)"

# Setup paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MCP_VENV_PATH="$HOME/.local/share/nvim/nvim-claude/mcp-env"

# Create MCP virtual environment
echo '📦 Creating MCP Python virtual environment...'
"$PYTHON_CMD" -m venv "$MCP_VENV_PATH"

# Install MCP (try fastmcp first, fallback to mcp)
echo '📥 Installing MCP package...'
"$MCP_VENV_PATH/bin/pip" install --quiet --upgrade pip

if "$MCP_VENV_PATH/bin/pip" install --quiet fastmcp; then
    echo 'fastmcp' > "$SCRIPT_DIR/requirements.txt"
    echo '✨ Using FastMCP (recommended)'
else
    echo '⚠️  FastMCP not available, using standard mcp package'
    "$MCP_VENV_PATH/bin/pip" install --quiet mcp
    echo 'mcp' > "$SCRIPT_DIR/requirements.txt"
fi

echo '✅ MCP server installed successfully!'
echo "   Using Python: $PYTHON_CMD ($PYTHON_VERSION)"
echo "   MCP environment: $MCP_VENV_PATH"
echo ''
echo 'To add to Claude Code, run this in your project directory:'
echo "  claude mcp add nvim-lsp -s local $MCP_VENV_PATH/bin/python $SCRIPT_DIR/nvim-lsp-server.py"
echo ''
echo 'Note: Use -s local to make it available only in the current project.'
echo 'The MCP server will automatically connect to the Neovim instance for that project.'