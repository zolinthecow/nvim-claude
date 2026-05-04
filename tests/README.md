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

### Run the OpenCode integration harness
```bash
./scripts/run_opencode_integration_test.sh
```

This drives the generated OpenCode plugin against a headless Neovim RPC server and checks baseline capture, tracked files, turn files, and rendered inline diff hunks. Use `NVIM_CLAUDE_KEEP_TMP=1` to preserve debug artifacts on failure.

## Test Structure

- `tests/hunks_spec.lua` - Action plan tests for hunks.lua
- `scripts/run_opencode_integration_test.sh` - End-to-end OpenCode plugin event harness

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
