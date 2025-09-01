#!/usr/bin/env bash
set -euo pipefail

# Run hunks.lua action plan tests with plenary

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Running hunks.lua action plan tests..."


if ! command -v nvim >/dev/null 2>&1; then
  echo "Error: Neovim (nvim) not found in PATH" >&2
  exit 1
fi

# Check plenary by trying to require it in a headless session
if ! nvim --headless -u tests/minimal_init.lua +"lua require('plenary')" +qa! >/dev/null 2>&1; then
  echo "Error: plenary.nvim not found. Please install it for tests." >&2
  echo "  Using lazy.nvim: { 'nvim-lua/plenary.nvim' }" >&2
  echo "  Using packer: use 'nvim-lua/plenary.nvim'" >&2
  exit 1
fi

# Run the specific spec file
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/hunks_spec.lua" \
  -c "qa!"

echo "✅ hunks.lua tests finished"
