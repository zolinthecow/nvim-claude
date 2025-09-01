# nvim-claude Tests (current focus: hunks action plans)

## Prerequisites

1. **plenary.nvim** - Required for test framework
   ```lua
   -- Using lazy.nvim
   { 'nvim-lua/plenary.nvim' }
   
   -- Using packer
   use 'nvim-lua/plenary.nvim'
   ```

2. **Git** - Must be installed and available in PATH

3. **Neovim 0.9+** - Required for extmark API

## Running Tests

### Run the current test suite
```bash
cd /path/to/nvim-claude
./scripts/run_tests.sh
```

### Run directly with Neovim (headless)
```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/hunks_spec.lua" -c "qa!"
```

## Test Structure

- `tests/hunks_spec.lua` - Action plan tests for hunks.lua

## Tests Cover (so far)

1. **Hunk Action Plans**
   - accept/reject individual hunks (existing/new files)
   - accept/reject all in file
   - batch accept/reject across open buffers

We’ll add more focused suites (executor, renderer, façade) as refactor completes.

## Troubleshooting

- **"plenary.nvim not found"** - Install plenary.nvim using your plugin manager
- **Git errors** - Ensure git is installed and `git config user.email` is set
- **Test failures** - Check that no other nvim instances are running with the same files open

## Adding New Tests

1. Add test case to `tests/hunks_spec.lua` or create a new spec file.
2. Keep tests focused on a single module/contract.
3. Use temporary git repos and headless buffers as shown.
