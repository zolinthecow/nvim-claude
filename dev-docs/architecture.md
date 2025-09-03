# Architecture

This doc is for a high level architecture overview of nvim-claude.

## Features
- inline diffs
- message checkpoints
- nvim LSP integration
- background agents

### Inline diffs
We use a commit-based baseline to track changes. When Claude edits files, we snapshot the project into a baseline git commit that captures the
pre-edit state. Inline diffs are simply the `git diff` between the current working tree and that baseline commit.

This naturally handles adds/deletes:
- New files do not exist in the baseline, so the diff is the whole file
- Deleted files exist only in the baseline, so the diff is the whole file in reverse

For accepting a hunk, we just need to compute the patch for that hunk specifically, then apply the patch to the version of the file in the
baseline commit. This way when we recompute the inline diff by taking the `git diff`, the hunk we just patch applied matches the state in 
the baseline commit so that hunk goes away. This works nicely too because we compute the diffs via `git diff`, so patch applying via git 
works very nicely.

We do the opposite for rejecting a hunk: compute the reverse patch and apply it to the working file.

The edge cases are for file creation/deletion, where if a file is created then instead of doing a patch apply we just create the file in
the baseline. And for rejecting a file creation we just delete the file. For accepting a file deletion we delete it from the baseline,
and for rejecting a file deletion we restore it from the baseline.

We track files via Claude Code hooks. A pre-tool-use hook captures the baseline commit before edits; a post-tool-use hook marks the file as
edited for this session and triggers/refreshes the inline diff.

If a tracked file has no more diffs left in it after a series of accept/rejects, then we remove it from tracking. If all files have no
more diffs, then we remove the baseline commit entirely.

### Message checkpoints
For message checkpoints, every time the user submits a message we take a snapshot of the state of the repo and store it in a different
git index. Then if someone wants to return to a previous state, we can let them browse that commit, and if they want to set it to that 
we create a merge and cherry-pick the merge commit onto the branch they were on before. 

### LSP integration
We expose LSP diagnostics to Claude via an MCP server. Each tool invocation spins up a headless Neovim that loads user config and attaches
LSP to real file paths, then waits briefly for diagnostics. This avoids UI freezes in the user's editor.

The Stop hook uses this server to validate all `session_edited_files` before allowing a turn to end. If errors are found, it blocks completion
and returns a JSON summary to Claude so it can fix issues.

### Background agents
Background agents basically just start claude code in a different tmux window with `--dangerously-skip-permissions` in a different 
worktree based off of either the master branch, the current branch, the state of the repo currently, or a different branch. It is instructed
to create a commit that can be cherry-picked back onto the branch it was based off of and its up to the user to figure out what to do
with that.

## Coding principles
We try to rely on git as much as possible since we don't want to reimplement things.

We also have a `project-state.lua` module that acts as a database, writing to a json file. We avoid keeping redundant state in memory; instead
we read/write from project-state and recompute when needed.

### Module layout (updated)
- Facades: `utils/` (`require('nvim-claude.utils')`), `events/` (`require('nvim-claude.events')`), `inline_diff/` (`require('nvim-claude.inline_diff')`), `lsp_mcp/`, `rpc/`
- Inline diff internals: `inline_diff/baseline.lua`, `diff.lua`, `render.lua`, `executor.lua`, `hunks.lua`, `navigation.lua`, `persistence.lua`
- Hooks: wrapper scripts in `claude-hooks/` installed into `.claude/settings.local.json` via `events/installer.lua`

### Facade pattern rules
- Keep facades thin: expose public API only; avoid business logic in `init.lua` files.
- Cross‑feature imports must go through the other feature’s facade (e.g., events ↔ inline_diff ↔ utils). Do not import another feature’s internals.
- Within a feature, internal modules may depend on each other.
