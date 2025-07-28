# nvim-claude

A Neovim plugin for seamless integration with Claude AI, featuring tmux-based chat workflow, inline diff reviews, per-file baseline management, and background agent management. ✨

## Features

- **Tmux Integration**: Chat with Claude in a dedicated tmux pane
- **Inline Diff Review**: Review and accept/reject Claude's code changes with inline diffs
- **Background Agents**: Create isolated worktrees for complex tasks
- **Git Integration**: Automatic stash creation and diff tracking
- **Smart Selection**: Send buffer content, visual selections, or git hunks to Claude
- **Persistent State**: Diff state persists across Neovim sessions

## Requirements

### Required
- Neovim >= 0.9.0
- [Claude Code CLI](https://claude.ai/download) - The `claude` command must be in your PATH
- Tmux (for chat interface and background agents)
- Git (for diff management and worktrees)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - Required dependency
- [neovim-remote](https://github.com/mhinz/neovim-remote) - Install with `pip install neovim-remote` or `pipx install neovim-remote`

### Optional but Recommended
- [diffview.nvim](https://github.com/sindrets/diffview.nvim) - For reviewing agent changes
- [which-key.nvim](https://github.com/folke/which-key.nvim) - For keybinding hints

### Notes
- The plugin creates a `.nvim-claude/` directory in your project root for storing state
- Neovim's server address is automatically saved to `.nvim-claude/nvim-server`
- On macOS, Claude Code CLI can be installed from the Claude desktop app
- The plugin uses git worktrees for agent isolation, so Git 2.5+ is recommended

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'zolinthecow/nvim-claude',
  config = function()
    require('nvim-claude').setup({
      -- your configuration
    })
  end,
  dependencies = {
    'nvim-lua/plenary.nvim',         -- Required
    'sindrets/diffview.nvim',        -- Optional: for enhanced diff viewing
  },
}
```

**Important**: After installation, run `:ClaudeInstallMCP` to install the MCP server dependencies. If you encounter "MCP install script not found", see the Troubleshooting section below.

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'zolinthecow/nvim-claude',
  config = function()
    require('nvim-claude').setup({
      -- your configuration
    })
  end,
  requires = {
    'nvim-lua/plenary.nvim',          -- Required
    'sindrets/diffview.nvim',          -- Optional
  }
}
```

## Configuration

```lua
require('nvim-claude').setup({
  tmux = {
    split_direction = 'h',      -- 'h' for horizontal, 'v' for vertical
    split_size = 40,            -- Percentage of window
    session_prefix = 'claude-', -- Tmux session prefix
    pane_title = 'claude-chat', -- Pane title
  },
  agents = {
    work_dir = '.agent-work',   -- Directory for agent worktrees
    use_worktrees = true,       -- Use git worktrees for agents
    auto_gitignore = true,      -- Auto-add work_dir to .gitignore
    max_agents = 5,             -- Maximum concurrent agents
    cleanup_days = 7,           -- Days before cleanup
  },
  ui = {
    float_diff = true,          -- Use floating windows for diffs
    telescope_preview = true,   -- Preview in telescope
    status_line = true,         -- Show status in statusline
  },
  mappings = {
    prefix = '<leader>c',       -- Main prefix for commands
    quick_prefix = '<C-c>',     -- Quick access prefix
  },
})
```

## Default Mappings

### Chat Commands
- `<leader>cc` - Open Claude chat in tmux pane
- `<leader>cs` - Send current buffer to Claude
- `<leader>cv` - Send visual selection to Claude (visual mode)
- `<leader>cd` - Send selection with diagnostics to Claude (visual mode)
- `<leader>ch` - Send git hunk at cursor to Claude

### Background Agent Management
- `<leader>cb` - Create a new background agent
- `<leader>cl` - List all agents
- `<leader>ck` - Kill a specific agent
- `<leader>cx` - Clean up old agents

### Checkpoint Commands
- `<leader>cp` - Browse checkpoints
- `<leader>cps` - Show checkpoint status
- `<leader>cpa` - Accept current checkpoint
- `<leader>cpr` - Return from checkpoint

### Inline Diff Review
When Claude makes changes to your files:

**Note:** Diffs automatically refresh when you save the file (`:w`). Use `<leader>if` to manually refresh without saving.

**Buffer-local keymaps (when viewing diffs):**
- `]h` / `[h` - Navigate to next/previous hunk
- `<leader>ia` - Accept current hunk
- `<leader>ir` - Reject current hunk
- `<leader>iA` - Accept all hunks in current file
- `<leader>iR` - Reject all hunks in current file
- `<leader>il` - List all files with Claude diffs
- `<leader>if` - Refresh inline diff (manual refresh)
- `<leader>iq` - Close inline diff view

**Global keymaps:**
- `<leader>ci` - List files with Claude diffs
- `<leader>IA` - Accept ALL diffs in ALL files
- `<leader>IR` - Reject ALL diffs in ALL files
- `]f` / `[f` - Navigate to next/previous file with diffs

## Commands

All commands below can be accessed via Ex commands. Those with keybindings are noted above.

### Basic Chat Commands
- `:ClaudeChat` - Open Claude chat (mapped to `<leader>cc`)
- `:ClaudeSendBuffer` - Send current buffer (mapped to `<leader>cs`)
- `:ClaudeSendSelection` - Send visual selection (mapped to `<leader>cv`)
- `:ClaudeSendWithDiagnostics` - Send with diagnostics (mapped to `<leader>cd`)
- `:ClaudeSendHunk` - Send git hunk at cursor (mapped to `<leader>ch`)

### Background Agent Commands
- `:ClaudeBg [task]` - Create new background agent (mapped to `<leader>cb`)
- `:ClaudeAgents` - List and manage agents (mapped to `<leader>cl`)
- `:ClaudeKill [id]` - Kill specific agent (mapped to `<leader>ck`)
- `:ClaudeKillAll` - Kill all active agents
- `:ClaudeClean` - Clean up old agents (mapped to `<leader>cx`)
- `:ClaudeSwitch [id]` - Switch to agent worktree
- `:ClaudeDiffAgent [id]` - Review agent changes with diffview
- `:ClaudeCleanOrphans` - Clean orphaned worktrees

### Checkpoint Commands
- `:ClaudeCheckpoints` - Browse checkpoints (mapped to `<leader>cp`)
- `:ClaudeCheckpointStatus` - Show status (mapped to `<leader>cps`)
- `:ClaudeCheckpointAccept` - Accept checkpoint (mapped to `<leader>cpa`)
- `:ClaudeCheckpointReturn` - Return from checkpoint (mapped to `<leader>cpr`)
- `:ClaudeCheckpointCreate <message>` - Create checkpoint manually
- `:ClaudeCheckpointRestore <id>` - Restore specific checkpoint

### Inline Diff Management
- `:ClaudeAcceptAll` - Accept all Claude's changes (same as `<leader>IA`)
- `:ClaudeResetBaseline` - Reset diff baseline
- `:ClaudeResetInlineDiff` - Reset inline diff state (use when corrupted)
- `:ClaudeCleanStaleTracking` - Clean up stale file tracking
- `:ClaudeUntrackFile` - Untrack current file from diff system
- `:ClaudeTrackModified` - Track all modified files for diff
- `:ClaudeUpdateBaseline` - Update baseline for current file
- `:ClaudeRestoreState` - Restore saved diff state

### Setup & Configuration
- `:ClaudeInstallHooks` - Install Claude Code hooks for this project
- `:ClaudeUninstallHooks` - Remove Claude Code hooks
- `:ClaudeInstallMCP` - Install MCP server dependencies
- `:ClaudeShowMCPCommand` - Show the command to add MCP server to Claude Code

### Debugging Commands
- `:ClaudeDebug` - Show general debug information
- `:ClaudeDebugAgents` - Debug agent state
- `:ClaudeDebugRegistry` - Debug agent registry
- `:ClaudeDebugInstall` - Debug plugin installation and paths
- `:ClaudeDebugInlineDiff` - Debug inline diff state
- `:ClaudeViewLog` - View debug log file
- `:ClaudeClearLog` - Clear debug log file

## Usage Examples

### Basic Chat Workflow
1. Open Claude chat with `<leader>cc`
2. Type your question or request
3. Claude's responses appear in the tmux pane

### Code Review Workflow
1. Make a request to Claude that involves code changes
2. When Claude edits files, inline diffs appear automatically
3. Navigate hunks with `]h` / `[h`
4. Accept with `<leader>ia` or reject with `<leader>ir`
5. Accept all changes in a file with `<leader>iA`
6. Navigate between files with diffs using `]f` / `[f`

### Background Agent Workflow
1. Create an agent: `:ClaudeAgent implement new feature X`
2. The agent works in an isolated git worktree
3. Check progress: `<leader>cas` to see all agents
4. Review changes: `<leader>cad` to see agent's diff
5. Switch to worktree: `<leader>caw` to work directly
6. Kill when done: `<leader>cak`

## Claude Code Hooks

The plugin can automatically create baselines and track changes when Claude edits files through the Claude Code CLI. Install hooks with:

```vim
:ClaudeInstallHooks
```

This creates a `.claude/settings.local.json` file in your project that integrates with Claude Code's hook system. This file is developer-specific and should not be committed to version control.

## Troubleshooting

### Installation Issues

#### MCP Install Script Not Found
If you get "MCP install script not found" when running `:ClaudeInstallMCP`:

1. **Debug the installation**: Run `:ClaudeDebugInstall` to see where the plugin is looking for files
2. **Check plugin structure**: Ensure the plugin was installed completely with the `mcp-server/` directory
3. **Manual installation**: If using a non-standard setup, you can manually run:
   ```bash
   cd ~/.local/share/nvim/lazy/nvim-claude  # or wherever your plugin is installed
   bash mcp-server/install.sh
   ```

### Debug Logging
The plugin includes comprehensive debug logging for diagnosing issues:
- **View logs**: `:ClaudeViewLog` - Opens the debug log file
- **Clear logs**: `:ClaudeClearLog` - Clears the debug log
- **Log location**: `.nvim-claude/debug.log` (project-specific) or `~/.local/share/nvim/nvim-claude-debug.log` (global)
- **Debug installation**: `:ClaudeDebugInstall` - Shows plugin paths and installation status

See [debugging.md](debugging.md) for detailed debugging information.

### Tmux Issues
- Ensure tmux is installed and you're running Neovim inside a tmux session
- Check tmux version compatibility (>= 2.0 recommended)

### Diff Not Showing
- Check `:ClaudeDebugInlineDiff` for state information
- View debug log with `:ClaudeViewLog` to see hook execution details
- Ensure git is available and you're in a git repository
- Try `:ClaudeResetBaseline` to reset the diff system
- If state is corrupted, use `:ClaudeResetInlineDiff`

### Agent Issues
- Check available disk space for worktrees
- Ensure git worktree support (git >= 2.5)
- Review agent logs in the tmux window

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - see LICENSE file for details
