# Changelog

All notable changes to nvim-claude will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Fixed "No baseline found" notification appearing on every file save
- Only show baseline warnings for corrupted states (Claude-tracked files with missing baseline)
- Fixed inline diff display timing issue by adding delay after buffer refresh

### Changed
- Removed redundant `diff_files` tracking - now using only `claude_edited_files` for all file tracking
- Simplified persistence state by removing `diff_files` from saved data
- File navigation now computes absolute paths from `claude_edited_files` when needed
- Claude Code hooks now use `settings.local.json` instead of `settings.json` for developer-specific configuration
- Hook installation now properly merges with existing hooks instead of overwriting
- Hook uninstallation only removes nvim-claude specific hooks, preserving user's custom hooks
- Gitignore now only ignores `.claude/settings.local.json` instead of entire `.claude/` directory

### Added
- Per-file baseline management for accurate diff tracking
- Hunk indicators for deletion-only hunks (shows `[Hunk X/Y]` on red deletion lines)
- Project-specific persistence directory `.nvim-claude/` for state isolation
- `:ClaudeResetInlineDiff` command to recover from corrupted baseline refs
- Validation to prevent git error messages from being stored as refs
- Automatic detection and cleanup of corrupted baseline refs on load
- Auto-refresh diffs on save (`:w`) with preserved cursor position
- Manual refresh keybinding `<leader>if` to update diffs without saving
- Immediate baseline persistence in pre-hook to handle multiple Neovim instances
- Stop hook validation that blocks Claude from completing when lint errors/warnings exist
- Session-based file tracking for targeted diagnostic checking

### Fixed
- Fixed phantom diff hunks at end of files caused by newline inconsistencies
- Fixed patch application in `accept_current_hunk` by using generic filenames in patch headers
- Fixed navigation crash when jumping to deletion-only hunks at EOF
- Fixed deletion-only hunks at EOF to display below the last line instead of above
- Fixed hunk indicator visibility on deletion-only hunks (was being pushed off-screen)
- Background agent creation now properly adds `.agent-work/` to gitignore before creating directories
- `<leader>cb` keybinding now opens the agent creation UI instead of waiting for text input
- Reject all operations now clear baseline tracking for consistency with accept all
- Critical bug where git command failures would store error messages as baseline refs
- Cascading failures caused by corrupted refs in subsequent operations
- Cross-project hook routing now uses edited file's project root instead of CWD
- Improved robustness of git command execution in baseline update operations
- Fixed baseline ref loss when pre-hook and post-hook connect to different Neovim instances
- Fixed cursor jumping during diff refresh by only refreshing on save instead of while typing
- Fixed manual edits in Claude-tracked files not showing as diffs

### Changed
- `<leader>cb` behavior changed to match `:ClaudeBg` command (opens interactive UI)
- Removed all debug logging for cleaner output
- Moved all state files from global locations to project-specific `.nvim-claude/` directory
- Server address now stored in `.nvim-claude/nvim-server` instead of `.nvim-server`
- Inline diff state now stored in `.nvim-claude/inline-diff-state.json` instead of global data directory
- Added robust error checking in `update_baseline_with_content()` and related functions
- `save_state()` now validates refs before persisting to prevent corruption
- Enhanced git command validation with better error detection and handling
- Separated blob creation from index update to improve error isolation

### Removed
- Vestigial `applied_hunks` field from inline diff data structures
- Empty `files` object from persistence state
- Unused `original_content` tracking and related commands
- Debug logging from all wrapper scripts and hook functions
- Unnecessary `new_content` field from `active_diffs` structure
- Debounced text change refresh in favor of save-only refresh

## [0.0.2] - 2025-01-12

### Fixed
- File path handling now properly escapes special characters in git root paths
- Stash references now use SHA hashes instead of `stash@{0}` for stability
- Accept/reject operations now properly remove files from tracking when all hunks are processed
- Persistence state is properly cleared when all tracked files are processed

### Added
- `reject_all_files()` function for rejecting all changes across all files
- Global keymap `<leader>IR` to reject all diffs in all files
- Comprehensive keymap documentation in README

### Changed
- Updated README with correct keybindings for inline diff operations
- Improved persistence handling to support both SHA and traditional stash references
- Better state management when accepting/rejecting hunks

## [0.0.1] - 2025-01-11

### Added
- Initial release
- Tmux integration for Claude chat
- Inline diff review system with stash-based tracking
- Background agent management with git worktrees
- Persistent diff state across Neovim sessions
- Claude Code hooks integration