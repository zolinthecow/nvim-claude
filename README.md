# nvim-claude

A powerful Neovim plugin for seamless integration with Claude AI. Chat with Claude directly in tmux, review code changes with inline diffs, and deploy background agents for complex tasks - all without leaving your editor. ✨

## Features

- **Tmux Integration**: Chat with Claude in a dedicated tmux pane
- **Inline Diff Review**: Review and accept/reject Claude's code changes with inline diffs
- **Background Agents**: Create isolated worktrees for complex tasks with guided setup
- **Checkpoint System**: Automatically save and restore codebase state at any point in chat history
- **LSP Integration**: Give Claude real-time access to LSP diagnostics via MCP
- **Smart Selection**: Send buffer content, visual selections, or git hunks to Claude

## Requirements

### Required
- Neovim >= 0.9.0
- [Claude Code CLI](https://claude.ai/download) - The `claude` command must be in your PATH
- Tmux (for chat interface and background agents)
- Git (for diff management and worktrees)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - Required dependency
- Python 3.10+ - For MCP server and RPC communication (automatically set up by `:ClaudeInstallMCP`)

### Optional but Recommended
- [diffview.nvim](https://github.com/sindrets/diffview.nvim) - For reviewing agent changes
- [which-key.nvim](https://github.com/folke/which-key.nvim) - For keybinding hints

### Notes
- The plugin stores state globally in `~/.local/share/nvim/nvim-claude/projects/`
- Project state is keyed by absolute path 
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

After installation:
1. **Automatic Setup**: The plugin automatically installs required components on first use
2. **Claude Code Hooks**: Run `:ClaudeInstallHooks` in your project to enable automatic diff tracking
3. **Manual Installation** (if needed):
   - `:ClaudeInstallRPC` - Install the Python RPC client for hook communication
   - `:ClaudeInstallMCP` - Install the MCP server for LSP diagnostics

If you encounter installation issues, see the Troubleshooting section below.

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

Configure nvim-claude during setup:

```lua
require('nvim-claude').setup({
  tmux = {
    split_direction = 'h',      -- 'h' for horizontal, 'v' for vertical
    split_size = 40,            -- Percentage of window
    pane_title = 'claude-chat', -- Pane title
  },
  mappings = {
    prefix = '<leader>c',       -- Main prefix for commands
  },
  mcp = {
    auto_install = true,        -- Automatically install MCP server on first use
    install_path = vim.fn.stdpath('data') .. '/nvim-claude/mcp-env',
  },
})
```

Default values are shown above. All configuration options are optional.

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
- `:ClaudeRebuildRegistry` - Rebuild agent registry from existing directories

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
- `:ClaudeInstallRPC` - Install Python RPC client for hook communication (required)
- `:ClaudeInstallMCP` - Install MCP server dependencies (optional, for LSP diagnostics)
- `:ClaudeShowMCPCommand` - Show the command to add MCP server to Claude Code

### Debugging Commands
- `:ClaudeDebug` - Show general debug information
- `:ClaudeDebugAgents` - Debug agent state
- `:ClaudeDebugRegistry` - Debug agent registry
- `:ClaudeDebugInstall` - Debug plugin installation and paths
- `:ClaudeDebugInlineDiff` - Debug inline diff state
- `:ClaudeViewLog` - View debug log file
- `:ClaudeClearLog` - Clear debug log file

### Project Management
- `:ClaudeListProjects` - List all projects tracked by nvim-claude
- `:ClaudeCleanupProjects [days]` - Clean up projects older than N days (default: 30)

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
1. Create an agent: `<leader>cb` or `:ClaudeBg`
2. **Interactive Setup**: 
   - Enter your mission with Task/Goals/Notes sections
   - Choose fork options (current branch, main branch, stash changes, etc.)
   - Configure setup instructions (auto-detects .env files, package managers, build scripts)
3. The agent works in an isolated git worktree with its own Claude instance
4. Monitor progress: `<leader>cl` to see all agents and their status
5. Review changes: `:ClaudeDiffAgent [id]` to see the agent's changes with diffview
6. **Complete the work**: When the agent finishes, it will automatically create a single commit with all changes
7. **Cherry-pick the commit**:
   - Switch to your main branch
   - Find the commit hash from the agent's response
   - Run: `git cherry-pick <commit-hash>`
8. Kill the agent: `<leader>ck` or `:ClaudeKill [id]`

**Why Cherry-pick?**: This workflow keeps your main branch history clean. The agent can make multiple exploratory commits, but you only cherry-pick the final, polished commit. This also makes it easy to:
- Review all changes in one commit
- Modify the commit message if needed
- Resolve any conflicts during cherry-pick
- Maintain a linear history

**Agent Instructions**: Each agent automatically receives guidelines for creating cherry-pickable commits, excluding metadata files (agent-instructions.md, CLAUDE.md, etc.) from commits.

### Checkpoint Workflow
1. Checkpoints are automatically created before each Claude message
2. Browse checkpoints with `<leader>cp` or `:ClaudeCheckpoints`
3. View the state of the codebase at any checkpoint by selecting it
4. Accept and merge a checkpoint with `<leader>cpa`
5. Return to the original state with `<leader>cpr`

## Claude Code Hooks

The plugin can automatically create baselines and track changes when Claude edits files through the Claude Code CLI. Install hooks with:

```vim
:ClaudeInstallHooks
```

This creates a `.claude/settings.local.json` file in your project that integrates with Claude Code's hook system. This file is developer-specific and should not be committed to version control.

## MCP Server Integration

The plugin includes an MCP (Model Context Protocol) server that gives Claude access to LSP diagnostics:

1. **Install the MCP server**:
   ```vim
   :ClaudeInstallMCP
   ```

2. **Get the configuration command**:
   ```vim
   :ClaudeShowMCPCommand
   ```

3. **Add to Claude Code config**: Copy the command output and add it to your Claude Code settings

Once configured, Claude can use these tools:
- `get_diagnostics` - Get diagnostics for specific files or all open buffers
- `get_diagnostic_context` - Get code context around specific diagnostics
- `get_diagnostic_summary` - Get a summary of all diagnostics
- `get_session_diagnostics` - Get diagnostics only for files edited in the current session

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
- **Log location**: `~/.local/share/nvim/nvim-claude/logs/<project-hash>-debug.log`
- **Debug installation**: `:ClaudeDebugInstall` - Shows plugin paths and installation status

See [debugging.md](dev-docs/debugging.md) for detailed debugging information.

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
