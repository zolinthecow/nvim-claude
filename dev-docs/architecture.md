# Architecture

This doc is for a high level architecture overview of nvim-claude.

## Features
- inline diffs
- message checkpoints
- nvim LSP integration
- background agents

### Inline diffs
We rely heavily on custom git indexes to track changes. For inline diffs, we maintain a baseline git index that contains the state of files
that were edited by claude *before* the edits were applied. This way all we have to do to display inline diffs is to take the `git diff` of
the current state of the file and the state of the file in the baseline commit. This works for regular edits and creations/deletions because
if a file was created it just won't be in the baseline at all, so the diff is the whole file. For deletions the file is in the baseline and
not in the current state, so the diff is also the whole file.

For accepting a hunk, we just need to compute the patch for that hunk specifically, then apply the patch to the version of the file in the
baseline commit. This way when we recompute the inline diff by taking the `git diff`, the hunk we just patch applied matches the state in 
the baseline commit so that hunk goes away. This works nicely too because we compute the diffs via `git diff`, so patch applying via git 
works very nicely.

We just do the opposite for rejecting a hunk, where we compute the reverse diff and just apply it to the current file.

The edge cases are for file creation/deletion, where if a file is created then instead of doing a patch apply we just create the file in
the baseline. And for rejecting a file creation we just delete the file. For accepting a file deletion we delete it from the baseline,
and for rejecting a file deletion we restore it from the baseline.

We know to track files via hooks. We have a pre and post tool use hook, where if claude is going to write/edit/mulitedit a file, then
*before* the edit is applied (pre tool use) we create a new baseline commit with that file included in it. This way we know the state
of the file before any claude edits were applied. Then after the edit goes through (post tool use), we add it to a list of claude edited
files and compute and display the inline diff for that file.

If a tracked file has no more diffs left in it after a series of accept/rejects, then we remove it from tracking. If all files have no
more diffs, then we remove the baseline commit entirely.

### Message checkpoints
For message checkpoints, every time the user submits a message we take a snapshot of the state of the repo and store it in a different
git index. Then if someone wants to return to a previous state, we can let them browse that commit, and if they want to set it to that 
we create a merge and cherry-pick the merge commit onto the branch they were on before. 

### LSP integration
To allow claude-code to view the LSP diagnostics that the user sees in their nvim, we have an MCP server that exposes some LSP tools.
Each LSP tool basically spins up a new nvim that it can talk to and get diagnostics from. We don't directly talk to the nvim instance
the user is using because getting the LSP diagnostics takes a second and the user's nvim ends up freezing for a bit every time the MCP
server gets used while it syncronously gets the LSP diagnostics. The workaround I went with was to just spin up another nvim instance
and just wait for diagnostics in that. 

The post tool use also accumulates a list of files edited by claude in the current turn, and when claude tries to end its turn it'll
check the LSP diagnostics on every single one of these files (session_edited_files) and tell claude if it introduced any LSP errors
in those files and give it a chance to fix them.

### Background agents
Background agents basically just start claude code in a different tmux window with `--dangerously-skip-permissions` in a different 
worktree based off of either the master branch, the current branch, the state of the repo currently, or a different branch. It is instructed
to create a commit that can be cherry-picked back onto the branch it was based off of and its up to the user to figure out what to do
with that.

## Coding principles
We try to rely on git as much as possible since we don't want to reimplement things.

We also have a `project-state.lua` module that acts as a database, writing to a json file. We try to avoid keeping any state stuff in 
memory. It's too easy to introduce synchronization errors when we have a "database" and also a global memory version of the same thing. It's
much better to just always read and write from the `project-state` and recompute whatever we need on the fly. I have not found anything that
is too expensive to recompute.
