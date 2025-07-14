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
- `<leader>cb` - Send current buffer to Claude
- `<leader>cv` - Send visual selection to Claude
- `<leader>ch` - Send git hunk at cursor to Claude

### Inline Diff Review
When Claude makes changes to your files:

**Buffer-local keymaps (when viewing diffs):**
- `]h` / `[h` - Navigate to next/previous hunk
- `<leader>ia` - Accept current hunk
- `<leader>ir` - Reject current hunk
- `<leader>iA` - Accept all hunks in current file
- `<leader>iR` - Reject all hunks in current file
- `<leader>il` - List all files with Claude diffs
- `<leader>iq` - Close inline diff view

**Global keymaps:**
- `<leader>ci` - List files with Claude diffs
- `<leader>IA` - Accept ALL diffs in ALL files
- `<leader>IR` - Reject ALL diffs in ALL files
- `]f` / `[f` - Navigate to next/previous file with diffs

### Agent Management
- `<leader>cA` - Create a new background agent
- `<leader>cas` - Show/switch between agents
- `<leader>cak` - Kill an agent
- `<leader>caw` - Switch to agent's worktree
- `<leader>cad` - Review agent's changes with diffview

## Commands

### Basic Commands
- `:Claude` - Open Claude chat
- `:ClaudeBuffer` - Send current buffer
- `:ClaudeSelection` - Send visual selection
- `:ClaudeHunk` - Send git hunk at cursor

### Agent Commands
- `:ClaudeAgent <task>` - Create new background agent
- `:ClaudeAgents` - List and manage agents
- `:ClaudeKillAgent [id]` - Kill specific agent
- `:ClaudeKillAll` - Kill all agents
- `:ClaudeSwitchAgent [id]` - Switch to agent worktree
- `:ClaudeDiffAgent [id]` - Review agent changes

### Diff Management
- `:ClaudeAcceptAll` - Accept all Claude's changes
- `:ClaudeResetBaseline` - Reset diff baseline
- `:ClaudeCleanStaleTracking` - Clean up stale file tracking

### Utility Commands
- `:ClaudeInstallHooks` - Install Claude Code hooks for this project
- `:ClaudeUninstallHooks` - Remove Claude Code hooks
- `:ClaudeDebugInlineDiff` - Debug inline diff state
- `:ClaudeDebugTracking` - Debug file tracking state

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

This creates a `.claude/settings.json` file in your project that integrates with Claude Code's hook system.

## Troubleshooting

### Tmux Issues
- Ensure tmux is installed and you're running Neovim inside a tmux session
- Check tmux version compatibility (>= 2.0 recommended)

### Diff Not Showing
- Check `:ClaudeDebugInlineDiff` for state information
- Ensure git is available and you're in a git repository
- Try `:ClaudeResetBaseline` to reset the diff system

### Agent Issues
- Check available disk space for worktrees
- Ensure git worktree support (git >= 2.5)
- Review agent logs in the tmux window

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

MIT License - see LICENSE file for details
