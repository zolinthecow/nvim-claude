#!/usr/bin/env bash
set -euo pipefail

# Run the hunks.lua action plan tests (current test suite)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Running nvim-claude tests (hunks.lua)..."

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

nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/inline_diff_unit_spec.lua" \
  -c "PlenaryBustedFile tests/events_spec.lua" \
  -c "PlenaryBustedFile tests/e2e_spec.lua" \
  -c "qa!"

echo "✅ Tests finished"
