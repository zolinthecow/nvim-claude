#!/bin/bash
set -e

echo '🔧 Setting up nvim-claude RPC client...'

# Function to check Python version
check_python_version() {
    local python_cmd=$1
    if command -v "$python_cmd" &> /dev/null; then
        local version=$("$python_cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        local major=$(echo $version | cut -d. -f1)
        local minor=$(echo $version | cut -d. -f2)
        if [[ $major -gt 3 ]] || [[ $major -eq 3 && $minor -ge 8 ]]; then
            echo "$python_cmd"
            return 0
        fi
    fi
    return 1
}

# Find suitable Python (>= 3.8, pynvim supports 3.8+)
PYTHON_CMD=""
for cmd in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3 python; do
    if check_python_version "$cmd"; then
        PYTHON_CMD="$cmd"
        break
    fi
done

if [[ -z "$PYTHON_CMD" ]]; then
    echo '❌ Error: Python 3.8 or higher is required for pynvim.'
    echo '   Your Python versions:'
    for cmd in python3 python; do
        if command -v "$cmd" &> /dev/null; then
            echo "   $cmd: $("$cmd" --version 2>&1)"
        fi
    done
    echo ''
    echo '   Please install Python 3.8+ using one of these methods:'
    echo '   • macOS: brew install python@3.11'
    echo '   • Ubuntu/Debian: sudo apt install python3.11'
    echo '   • pyenv: pyenv install 3.11.0'
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_CMD" --version 2>&1 | cut -d' ' -f2)
echo "✅ Found suitable Python: $PYTHON_CMD (version $PYTHON_VERSION)"

# Setup paths
RPC_VENV_PATH="$HOME/.local/share/nvim/nvim-claude/rpc-env"

# Create RPC virtual environment
echo '📦 Creating RPC Python virtual environment...'
"$PYTHON_CMD" -m venv "$RPC_VENV_PATH"

# Install pynvim for RPC communication
echo '📥 Installing pynvim for Neovim RPC...'
"$RPC_VENV_PATH/bin/pip" install --quiet --upgrade pip
"$RPC_VENV_PATH/bin/pip" install --quiet pynvim

echo '✅ RPC client installed successfully!'
echo "   Using Python: $PYTHON_CMD ($PYTHON_VERSION)"
echo "   RPC environment: $RPC_VENV_PATH"
echo ''
echo 'The RPC client is now ready for use by nvim-claude hooks.'