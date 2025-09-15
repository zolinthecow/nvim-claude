#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Running E2E simulated hooks tests..."

if ! command -v nvim >/dev/null 2>&1; then
  echo "Error: Neovim (nvim) not found in PATH" >&2
  exit 1
fi

if ! nvim --headless -u tests/minimal_init.lua +"lua require('plenary')" +qa! >/dev/null 2>&1; then
  echo "Error: plenary.nvim not found. Please install it for tests." >&2
  exit 1
fi

nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/e2e_spec.lua" \
  -c "qa!"

echo "✅ E2E tests finished"

