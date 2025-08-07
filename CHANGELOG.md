# Changelog

All notable changes to nvim-claude will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v0.1.1] - 2025-08-05

### Added
- `:ClaudeRebuildRegistry` command to rebuild agent registry from existing directories
  - Discovers agent directories created before registry system was implemented
  - Automatically detects git worktrees and tmux windows
  - Useful for migrating old agents to the new registry system
- Agent setup instructions stage in creation workflow
  - New UI stage between fork options and agent creation
  - Automatically detects common setup patterns:
    - Copies `.env` files from main project (`cp ../../.env .`)
    - Detects package managers (npm/yarn/pnpm) and suggests install commands
    - Detects build scripts and suggests build commands
    - Supports Python, Ruby, Go, and other language-specific setups
  - Remembers successful setup commands for future agents in same project
  - Setup instructions are prominently displayed in agent-instructions.md
- Commit guidelines in agent instructions
  - Clear instructions for creating cherry-pickable commits
  - Reminds agents to exclude metadata files (agent-instructions.md, CLAUDE.md, mission.log, etc.)
  - Encourages single, focused commits with proper commit messages
  - Notifies user about the single commit to be cherry-picked

### Changed
- Agent instructions now use `agent-instructions.md` instead of deprecated `CLAUDE.local.md`
  - Follows new Claude Code memory system with `@import` directives
  - Creates/updates `CLAUDE.md` with `@import agent-instructions.md`
  - Cleaner separation of agent-specific and project-wide instructions
- Task formatting improvements
  - Agent prompts now properly formatted with `# Task`, `# Goals`, `# Notes` sections
  - Sections with only `- ` are treated as empty and omitted
  - Better parsing of multi-line mission descriptions
- UI text improvements
  - Fork options screen now says "Press <Tab> to configure setup instructions"
  - Setup screen says "Press <Tab> to start agent" for clarity
- Branch selection UI now uses consistent navigation style
  - Arrow indicator moves up/down with j/k or arrow keys
  - Press Tab or Enter to select the highlighted branch
  - Maintains number key shortcuts for quick selection
  - Uses same telescope-like styling as other UI screens
- Agent setup UI divider lines now stretch full window width
  - Dividers dynamically adjust to window size instead of fixed length
  - Provides cleaner visual separation in the setup instructions panel

### Fixed
- Background agents now properly start Claude in the agent work directory
  - Added `cd` command before launching Claude to ensure correct working directory
  - Fixed issue where Claude would start in the main project instead of agent directory
- Fixed error in `<leader>cl` (list agents) when agent tasks contain newlines
  - Properly sanitize multi-line task descriptions to single line for display
  - Prevents "replacement string contains newlines" error
- Fixed task formatting to properly exclude empty Goals and Notes sections
  - Mission extraction now preserves section headers (`## Task:`, `## Goals:`, `## Notes:`)
  - Empty sections containing only `-` are correctly omitted from agent prompt
  - Agent receives clean, properly formatted task without empty sections
- Added Shift-Tab navigation in agent creation flow
  - Users can now press Shift-Tab to go back to previous screens
  - Navigate from fork options back to mission input
  - Navigate from setup instructions back to fork options
  - All three UI screens now show navigation hints including Shift-Tab
- Fixed MCP diagnostic tools closing inline diff views
  - MCP bridge now properly restores inline diffs after refreshing buffers
  - Stores diff state (current hunk, cursor position) before refresh
  - Restores inline diff view automatically after LSP diagnostics update
  - Ensures fresh diagnostics while preserving the diff review experience
- Removed debug "Diff refreshed" notification when editing files with inline diffs
- Fixed stop hook not detecting LSP errors reliably
  - Now uses the same robust diagnostic refresh mechanism as MCP tools
  - Properly waits for all LSP servers to analyze files
  - Refreshes existing buffers to ensure fresh diagnostics
- Refactored LSP diagnostic utilities into shared module
  - Created `lsp-utils.lua` to avoid code duplication
  - Both MCP bridge and stop hook now use the same robust implementation
- Fixed E37 "No write since last change" error when loading files after LSP diagnostics
  - Buffer modification tracking now properly handles diagnostic refreshes
  - Avoids marking buffers as modified when only triggering LSP analysis
- Improved file tracking to automatically untrack files that match baseline
  - If Claude edits a file then reverts all changes, the file is removed from tracking
  - Prevents confusion when files show as "Claude-edited" but have no actual changes
  - Helps handle interrupted messages where Claude may have reverted its own edits

## [0.1.0] - 2025-08-04

### Added
- **Global state storage system** - All plugin state now stored globally instead of project directories
  - State files moved from `.nvim-claude/` to `~/.local/share/nvim/nvim-claude/`
  - Project identification using filesystem paths for proper isolation
  - Automatic migration from local to global storage on first load
  - `:ClaudeListProjects` command to view all projects with state
  - `:ClaudeCleanupProjects` command to remove state for deleted projects
- Checkpoint system that automatically saves codebase state before each Claude message
  - Time-travel feature to browse and restore any previous checkpoint
  - Preview mode for safely exploring checkpoints without committing
  - Merge commits when accepting checkpoints for easy reversion
  - UserPromptSubmit hook integration for automatic checkpoint creation
  - Only displays 5 most recent checkpoints for performance
- Base64 encoding for all hooks to handle special characters in file paths and prompts
- Missing `log` function in `hook-common.sh`
- File deletion tracking for rm commands (completed from work-in-progress)
- Cursor-relative hunk navigation - `]h` and `[h` now navigate relative to cursor position instead of stored state
- `:ClaudeKillAll` command to terminate all background agents
- **Python-based RPC client** to replace `nvr` (neovim-remote) dependency
  - New `nvim_rpc.py` script using `pynvim` library for Neovim communication
  - Wrapper script `nvim-rpc.sh` to manage Python virtual environment
  - `:ClaudeInstallRPC` command to install the RPC client separately
  - Automatic project-specific Neovim server discovery
- Separate installation scripts for RPC and MCP components
  - `scripts/install-rpc.sh` for Python RPC client with pynvim
  - MCP server installation remains in `mcp-server/install.sh`
  - Each component uses its own Python virtual environment

### Changed
- **Breaking**: Plugin state no longer stored in project directories
  - `.nvim-claude/` directories are no longer created in projects
  - Server files now stored in system temp directory (`/tmp` or `$XDG_RUNTIME_DIR`)
  - Logs stored globally at `~/.local/share/nvim/nvim-claude/logs/`
- Background agents now start in their working directory instead of main project
- Agent instructions stored in `agent-instructions.md` with import in `CLAUDE.md`
- Agent registry is now project-specific instead of global
- Branch selection UI starts in normal mode instead of insert mode
- Checkpoint creation now uses temporary git index to avoid polluting staging area
- Optimized checkpoint listing from O(n) to O(1) - uses single git command instead of multiple
- All hooks (pre/post tool use, bash, user prompt) now use base64 encoding to avoid shell escaping issues
- MCP server updated to find Neovim server in new temp directory location
- **Breaking**: Removed `nvr` (neovim-remote) dependency
  - All hook scripts now use `nvim-rpc.sh` instead of `nvr-proxy.sh`
  - Updated pre-hook, post-hook, user-prompt-hook, stop-hook, and bash-hook wrappers
  - Git pre-commit hook updated to use new RPC client
- Fixed Python version detection in install scripts
  - Removed `bc` dependency for version comparison
  - Now uses pure bash arithmetic for version checks
- Updated documentation to reflect RPC client changes
  - README.md now lists Python 3.8+ as requirement instead of nvr
  - CLAUDE.md updated with new debugging commands and examples

### Fixed
- Accept hunk functionality now properly handles files without trailing newlines
- Hook string escaping issues with apostrophes and special characters
- Background agents properly stash untracked files with `-u` flag
- Stash application in agents uses SHA references for cross-worktree compatibility
- Server file writing delay issue causing hook communication failures
- Hardcoded paths in `user-prompt-hook-wrapper.sh` and `stop-hook-validator.sh`
  - Now dynamically finds files in current project directory
  - No longer has user-specific paths hardcoded
- LSP diagnostics stale data issues
  - Fixed path construction bug in `get_session_diagnostic_counts`
  - Now stores full paths instead of relative paths in `session_edited_files`
  - Added `_refresh_buffer_diagnostics` helper to clear stale diagnostics
- **MCP diagnostics reliability** - Diagnostics no longer return stale or empty results
  - Added `_await_lsp_diagnostics` function that waits for LSP servers to finish analysis
  - Tracks which LSP clients are attached to each buffer
  - Uses `DiagnosticChanged` autocmd to detect when each LSP has reported
  - Waits up to 3 seconds for all expected LSPs to publish diagnostics
  - Returns as soon as all LSPs report (no unnecessary waiting)
  - Falls back to partial results if timeout is reached
  - All MCP diagnostic tools now use this waiting mechanism
- Navigation with deleted files (`]f` and `[f` commands)
  - Now properly checks file existence before opening
  - Uses special deleted file handler for non-existent files
  - Added `vim.defer_fn` for proper highlighting
- ClaudeChat (`<leader>cc`) command not showing tmux pane
  - Added explicit `tmux select-pane` command after pane creation
  - Ensures new pane is focused and visible to user
- Rejecting new files created by Claude now properly deletes them instead of leaving empty files

## [0.0.4] - 2025-07-26

### Changed
- Replaced git stash-based baseline system with git commit objects and custom refs
  - Baselines now stored in `refs/nvim-claude/baseline` instead of stash list
  - No longer pollutes user's git stash list with nvim-claude entries
  - Properly includes untracked files in baselines using temporary git index
  - Preserves user's staging area during baseline creation

### Fixed
- Fixed cursor jumping to first diff hunk when Claude edits an open buffer
  - Added `preserve_cursor` option to maintain cursor position during diff updates
- Fixed "reject all" (`<leader>iR`) command that was accepting changes instead of rejecting
  - Now properly replaces file content with baseline version
- Fixed stale LSP diagnostics not refreshing when files change
  - Added buffer refresh before querying diagnostics
  - Dynamically waits for LSP attachment instead of fixed delay
- Fixed error messages showing for new files in inline diffs
  - Properly detects git errors when files don't exist in baseline
  - Shows new files as all additions (green) without error text
- Fixed baseline not persisting after accepting changes for new files
  - Unified baseline reference to single source of truth in persistence module
  - Eliminated dual reference synchronization bugs
- Fixed stop hook firing when no files were edited
  - Now only checks diagnostics for files edited in current session
  - Prevents interruptions during non-editing conversations
- Fixed persistence module not being required before use in hooks.lua
- Fixed missing require statement in reject_all_hunks function causing nil reference error
  - Caused "attempt to index global 'persistence' (a nil value)" error

### Changed
- Refactored baseline reference management to use single source of truth
  - All baseline access now goes through `persistence.get_baseline_ref()` and `set_baseline_ref()`
  - Removed `hooks.stable_baseline_ref` in favor of `persistence.current_stash_ref`
  - Updated all code and documentation to reflect new architecture

### Added
- Comprehensive onboarding section to CLAUDE.md for future Claude instances
  - Key concepts, common gotchas, and debugging workflow
  - Architecture overview and mental model
  - Common tasks and where to look when things break

## [0.0.3] - 2025-07-16

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
- MCP server integration with 4 diagnostic tools: `get_diagnostics`, `get_diagnostic_summary`, `get_session_diagnostics`, `get_diagnostic_context`
- LSP diagnostics bridge for Claude to query and understand errors/warnings in real-time

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
