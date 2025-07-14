# nvim-claude Debug Tasks

## Current Issues to Fix

### 1. `<leader>ci` not showing newly edited files (Priority: High)
**Problem**: When Claude edits a file that wasn't already open, `<leader>ci` doesn't show it in the list. The tracking is happening but the menu isn't refreshed.

**Location**: Likely in the `<leader>ci` command implementation 
**Expected behavior**: `<leader>ci` should show all Claude-edited files, including newly edited ones

### 2. Ghost diff at end of files (Priority: Medium)
**Problem**: Phantom "Hunk 2/2" appears at the end of files even when no changes were made there. Shows as "SOFTWARE." -> "SOFTWARE." diff.

**Location**: Likely in `inline-diff.lua` - diff parsing or hunk detection logic
**Expected behavior**: Only show actual hunks where changes occurred

## Investigation Notes

- ✅ **COMPLETED**: Baseline stash management - Now properly handles per-file baselines and new files
- Issue #2 (ghost diff) appears to be a diff parsing bug rather than actual file modification
- Issue #1 (`<leader>ci` refresh) likely needs investigation of the command implementation

## Next Steps

1. Fix #1 - `<leader>ci` not showing newly edited files
2. Debug #2 - fix phantom hunk detection
