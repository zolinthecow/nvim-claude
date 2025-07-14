#!/bin/bash

# Run inline-diff tests

cd "$(dirname "$0")"

echo "Running nvim-claude inline-diff tests..."

# Run with plenary if available
if nvim --headless -c "lua require('plenary')" -c "q" 2>/dev/null; then
  nvim --headless -c "PlenaryBustedFile tests/inline-diff_spec.lua" -c "qa!"
else
  echo "Error: plenary.nvim not found. Please install it first:"
  echo "  Using lazy.nvim: { 'nvim-lua/plenary.nvim' }"
  echo "  Using packer: use 'nvim-lua/plenary.nvim'"
  exit 1
fi