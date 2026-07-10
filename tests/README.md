# nvim-claude Tests

## Prerequisites

1. **plenary.nvim** - Required for test framework
   ```lua
   -- Using lazy.nvim
   { 'nvim-lua/plenary.nvim' }
   
   -- Using packer
   use 'nvim-lua/plenary.nvim'
   ```

2. **Git** - Must be installed and available in PATH

3. **Neovim 0.10+** - Required by the LSP and hook adapters

## Running Tests

### Run the current test suite
```bash
cd /path/to/nvim-claude
./scripts/run_tests.sh
```

### Run one spec directly with Neovim (headless)
```bash
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/inline_diff_unit_spec.lua" -c "qa!"
```

### Check package boundaries

```bash
nvim --headless -u NONE -l scripts/check_dependency_direction.lua
```

### Run the OpenCode integration harness
```bash
./scripts/run_opencode_integration_test.sh
```

This drives the generated OpenCode plugin against a headless Neovim RPC server and checks baseline capture, tracked files, turn files, and rendered inline diff hunks. Use `NVIM_CLAUDE_KEEP_TMP=1` to preserve debug artifacts on failure.

## Test Structure

- `tests/inline_diff_unit_spec.lua` covers hunk plans, executor ordering, loaded-buffer behavior, empty/deleted files, and global batch actions.
- `tests/checkpoint_background_spec.lua` covers recoverable checkpoint transactions, exact index restoration, registry isolation, and worktree rollback.
- `tests/events_spec.lua` covers the event and review-state lifecycle.
- `tests/project_state_spec.lua` covers atomic storage, corrupt input, and cross-process updates.
- `tests/project_state_schema_spec.lua` covers persisted-state normalization.
- `tests/provider_safety_spec.lua` covers non-destructive Claude/Codex/OpenCode configuration.
- `tests/lsp_mcp_spec.lua` covers diagnostic buffer ownership and filetype detection.
- `tests/e2e_spec.lua` covers repository-level inline-diff workflows.
- `scripts/run_opencode_integration_test.sh` drives the generated OpenCode plugin end to end.

## Troubleshooting

- **"plenary.nvim not found"** - Install plenary.nvim using your plugin manager
- **Git errors** - Ensure git is installed and `git config user.email` is set
- **Test failures** - Check that no other nvim instances are running with the same files open

## Adding New Tests

1. Add a test to the closest `tests/*_spec.lua` file or create a focused spec.
2. Keep tests focused on a single module/contract.
3. Use temporary git repos and headless buffers as shown.
