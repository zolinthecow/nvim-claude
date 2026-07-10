#!/usr/bin/env bash
set -euo pipefail

# Run every focused Plenary spec.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Running nvim-claude tests..."

if ! command -v nvim >/dev/null 2>&1; then
  echo "Error: Neovim (nvim) not found in PATH" >&2
  exit 1
fi

# Check plenary presence in a headless session
if ! nvim --headless -u tests/minimal_init.lua +"lua require('plenary')" +qa! >/dev/null 2>&1; then
  echo "Error: plenary.nvim not found. Please install it first:" >&2
  echo "  Using lazy.nvim: { 'nvim-lua/plenary.nvim' }" >&2
  echo "  Using packer: use 'nvim-lua/plenary.nvim'" >&2
  exit 1
fi

for spec in tests/*_spec.lua; do
  echo "==> $spec"
  nvim --headless -u tests/minimal_init.lua \
    -c "PlenaryBustedFile $spec" \
    -c "qa!"
done

echo "Tests finished"
