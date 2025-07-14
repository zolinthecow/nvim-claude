# nvim-claude Inline Diff Tests

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

### Option 1: Use the test runner script
```bash
cd /path/to/nvim-claude
./run_tests.sh
```

### Option 2: Run directly with Neovim
```bash
# Run all tests
nvim --headless -c "PlenaryBustedFile tests/inline-diff_spec.lua"

# Run specific test suite
nvim --headless -c "PlenaryBustedFile tests/inline-diff_spec.lua" -c "qa!" | grep -E "(✓|✗|describe)"
```

### Option 3: Run interactively (for debugging)
```vim
:PlenaryBustedFile tests/inline-diff_spec.lua
```

## Test Structure

- `tests/inline-diff_spec.lua` - Main test suite with ~10 core tests
- `tests/helpers.lua` - Test utilities for git operations and mocking
- `tests/fixtures/` - Sample files used in tests

## Tests Cover

1. **Basic Hunk Operations** - Accept/reject individual hunks
2. **Batch Operations** - Accept/reject all hunks in file or project
3. **Edge Cases** - Deletion-only hunks, concurrent editing, git failures, undo/redo
4. **State & Persistence** - Session restoration, invalid stash recovery
5. **Navigation** - Hunk and file navigation

## Troubleshooting

- **"plenary.nvim not found"** - Install plenary.nvim using your plugin manager
- **Git errors** - Ensure git is installed and `git config user.email` is set
- **Test failures** - Check that no other nvim instances are running with the same files open

## Adding New Tests

1. Add test case to appropriate `describe()` block in `inline-diff_spec.lua`
2. Use helpers from `tests/helpers.lua` for common operations
3. Follow existing patterns for test structure and assertions