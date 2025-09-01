#!/bin/bash
set -e

echo '🔧 Setting up nvim-claude RPC client...'

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

PYTHON_CMD=""
for cmd in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3 python; do
    if check_python_version "$cmd"; then
        PYTHON_CMD="$cmd"
        break
    fi
done

if [[ -z "$PYTHON_CMD" ]]; then
    echo '❌ Error: Python 3.8 or higher is required for pynvim.'
    exit 1
fi

PYTHON_VERSION=$("$PYTHON_CMD" --version 2>&1 | cut -d' ' -f2)
echo "✅ Found suitable Python: $PYTHON_CMD (version $PYTHON_VERSION)"

RPC_VENV_PATH="$HOME/.local/share/nvim/nvim-claude/rpc-env"

echo '📦 Creating RPC Python virtual environment...'
"$PYTHON_CMD" -m venv "$RPC_VENV_PATH"

echo '📥 Installing pynvim for Neovim RPC...'
"$RPC_VENV_PATH/bin/pip" install --quiet --upgrade pip
"$RPC_VENV_PATH/bin/pip" install --quiet pynvim

echo '✅ RPC client installed successfully!'
echo "   Using Python: $PYTHON_CMD ($PYTHON_VERSION)"
echo "   RPC environment: $RPC_VENV_PATH"

