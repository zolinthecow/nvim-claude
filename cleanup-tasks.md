# nvim-claude Codebase Cleanup Tasks

This document contains a comprehensive list of cleanup tasks to remove vestigial code and improve the codebase architecture. The plugin has evolved from a complex persistence system to a clean git-baseline-driven approach, leaving some unused code that should be removed.

## Background Context

The inline diff system previously saved hunks, applied_hunks, and file content in JSON persistence files. This has been replaced with a cleaner approach that only persists git baseline references and computes all diffs fresh from git. However, some old code patterns remain.

**Current Clean Architecture:**
- Git stash SHA as baseline reference (`stable_baseline_ref`)
- Fresh diff computation via `git diff` between baseline and current state
- Lightweight persistence (only stash ref + file tracking)
- No cached diff data

## 1. Remove Vestigial Data Structures

### 1.1 Remove `applied_hunks` Field
**Files:** `lua/nvim-claude/inline-diff.lua`

The `applied_hunks` field is always initialized as an empty array and never used:

```lua
-- Lines ~200-210 in show_inline_diff()
M.active_diffs[bufnr] = {
  hunks = diff_data.hunks,
  new_content = new_content,
  current_hunk = 1,
  applied_hunks = {},  -- <-- REMOVE THIS LINE
}
```

**Action:** Remove all references to `applied_hunks` throughout the file.

### 1.2 Remove Empty `files` Object in Persistence
**Files:** `lua/nvim-claude/inline-diff-persistence.lua`

Line 57 contains an unused `files = {}` field:

```lua
local state = {
  version = 1,
  timestamp = os.time(),
  stash_ref = diff_data.stash_ref,
  claude_edited_files = diff_data.claude_edited_files or hooks.claude_edited_files or {},
  diff_files = {},
  files = {}  -- <-- REMOVE THIS LINE
}
```

**Action:** Remove the `files = {}` line and any references to `state.files`.

## 2. Clean Up Debug/Unused Code

### 2.1 Remove `original_content` Tracking
**Files:** `lua/nvim-claude/hooks.lua`

The `original_content` system appears to be an old in-memory baseline system that's no longer used in the main diff flow. Search for and remove:

- `inline_diff.original_content[bufnr]` assignments
- Any functions that populate or use `original_content`
- Debug prints that reference `original_content`

**Verification:** Ensure removal doesn't break the current git-baseline diff system.

### 2.2 Remove Old In-Memory Baseline Logic
**Files:** `lua/nvim-claude/hooks.lua`

Look for commented-out or deprecated code related to in-memory baselines around lines 739, 814, 416-417. These may include:

- Old commit creation logic
- Deprecated baseline management functions  
- Unused baseline update mechanisms

**Action:** Remove any code that's clearly unused and not part of the current stash-based system.

### 2.3 Clean Up Debug Logging
**Files:** Multiple files

Remove or standardize debug logging:

- `/tmp/nvim-claude-stash-debug.log` (in `inline-diff-persistence.lua`)
- `/tmp/nvim-claude-hook-debug.log` (in `hooks.lua`)

**Options:**
1. Remove debug logging entirely
2. Standardize on a single debug approach
3. Make debug logging configurable

## 3. Simplify Data Structures

### 3.1 Simplify `active_diffs` Structure
**Files:** `lua/nvim-claude/inline-diff.lua`

Current structure:
```lua
M.active_diffs[bufnr] = {
  hunks = diff_data.hunks,
  new_content = new_content,
  current_hunk = 1,
  applied_hunks = {},  -- Unused
}
```

Simplified structure:
```lua
M.active_diffs[bufnr] = {
  hunks = diff_data.hunks,
  current_hunk = 1,
  -- new_content can be retrieved from buffer when needed
}
```

**Rationale:** `new_content` is always available from the buffer, and `applied_hunks` is unused.

### 3.2 Review `diff_files` Usage
**Files:** `lua/nvim-claude/inline-diff.lua`, `lua/nvim-claude/inline-diff-persistence.lua`

The `diff_files` tracking serves multiple purposes:
- File navigation for `<leader>ci` command
- Persistence of which files have diffs
- Buffer number tracking

**Action:** Verify this structure is necessary and consider simplification if possible.

## 4. Code Organization Improvements

### 4.1 Consolidate Stash Reference Management
**Files:** `lua/nvim-claude/hooks.lua`, `lua/nvim-claude/inline-diff-persistence.lua`

Currently stash references are managed in multiple places:
- `hooks.stable_baseline_ref`
- `persistence.current_stash_ref`

**Action:** Centralize stash reference management in one module to reduce duplication.

### 4.2 Extract Git Operations
**Files:** Multiple files

Git operations are scattered throughout:
- Stash creation in `inline-diff-persistence.lua`
- Diff computation in `inline-diff.lua`
- Baseline updates in `hooks.lua`

**Action:** Consider creating a dedicated `git.lua` module (note: one already exists for worktrees) or `git-operations.lua` for all git interactions.

## 5. Function-Level Cleanup

### 5.1 Review `restore_diffs()` Function
**Files:** `lua/nvim-claude/inline-diff-persistence.lua` (lines 140-192)

This function has complex logic for restoring diff_files that may be overly complicated:

```lua
-- Lines 164-172: Complex unopened file handling
if state.diff_files then
  for file_path, bufnr in pairs(state.diff_files) do
    if not inline_diff.diff_files[file_path] then
      inline_diff.diff_files[file_path] = bufnr == -1 and -1 or -1  -- Redundant logic
    end
  end
end
```

**Action:** Simplify this logic and ensure it's actually necessary.

### 5.2 Review Stash Validation Logic
**Files:** `lua/nvim-claude/inline-diff-persistence.lua` (lines 100-126)

The stash validation has complex logic for different reference types:

```lua
-- Check if it's a SHA (40 hex chars) or a stash reference
local is_sha = state.stash_ref:match('^%x+$') and #state.stash_ref >= 7
```

**Action:** Since we standardized on SHA references, consider simplifying this validation.

## 6. Documentation and Comments

### 6.1 Update Inline Comments
**Files:** All files

Many comments reference the old persistence system:

- Update comments that mention saving hunks/content
- Remove outdated architecture descriptions
- Add clear comments about the current git-baseline approach

### 6.2 Update CLAUDE.md
**Files:** `CLAUDE.md`

Ensure the architecture documentation accurately reflects the current implementation and doesn't reference removed features.

## 7. Testing and Validation

### 7.1 Test Commands After Cleanup
After performing cleanup tasks, verify these commands still work:

- `<leader>ca` (accept hunk)
- `<leader>cr` (reject hunk)  
- `<leader>ci` (iterate through files with diffs)
- `<leader>cv` (send selection to Claude)
- `:ClaudeDebugInlineDiff`

### 7.2 Test Persistence Across Sessions
Verify that:
- Diffs persist across Neovim restarts
- File tracking works correctly
- Stash references remain valid

### 7.3 Test Error Conditions
- Invalid stash references
- Missing git repository
- Corrupted state files

## 8. Implementation Priority

**High Priority (Core Cleanup):**
1. Remove `applied_hunks` field (section 1.1)
2. Remove empty `files` object (section 1.2)
3. Remove `original_content` tracking (section 2.1)

**Medium Priority (Code Quality):**
4. Clean up debug logging (section 2.3)
5. Simplify `active_diffs` structure (section 3.1)
6. Update comments and documentation (section 6)

**Low Priority (Architecture):**
7. Consolidate stash management (section 4.1)
8. Extract git operations (section 4.2)
9. Simplify complex functions (section 5)

## 9. Implementation Notes

- **Backward Compatibility:** Some changes may affect saved state files. Consider migration logic if needed.
- **Testing:** Test each change incrementally to avoid breaking the working system.
- **Git Safety:** Ensure cleanup doesn't affect the core git stash functionality.
- **User Impact:** These are internal changes that shouldn't affect user-facing behavior.

## 10. Success Criteria

After cleanup, the codebase should:
- Have no unused data structures or fields
- Use only git baseline + current state for diff calculations
- Have clean, focused functions with single responsibilities
- Have accurate documentation and comments
- Maintain all existing functionality
- Be easier to understand and maintain

This cleanup will result in a leaner, more maintainable codebase that clearly reflects the current git-baseline architecture without vestigial code from the old persistence system.