# nvim-claude Installation Guide

This guide helps troubleshoot common installation issues with nvim-claude.

## Quick Installation Check

After installing nvim-claude with your package manager, run this command in Neovim:

```vim
:ClaudeDebugInstall
```

This will show you:
- Where the plugin was installed
- Whether the mcp-server directory exists
- The status of MCP server installation

## Common Issues and Solutions

### "MCP install script not found"

This error occurs when the `mcp-server` directory is missing from your installation. 

**Possible causes:**

1. **Incomplete clone**: Your package manager might not have cloned the full repository
2. **Shallow clone**: Some package managers use shallow clones by default
3. **Directory exclusion**: Your config might exclude certain directories

**Solutions:**

#### For lazy.nvim users:

Update your configuration to ensure full clone:

```lua
{
  'zolinthecow/nvim-claude',
  build = false,  -- Ensure no build step interferes
  config = function()
    require('nvim-claude').setup({})
  end,
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
}
```

Then reinstall:
1. Run `:Lazy`
2. Find nvim-claude in the list
3. Press `x` to delete it
4. Press `I` to reinstall

#### Manual verification:

Check if the plugin was fully installed:

```bash
# For lazy.nvim
ls -la ~/.local/share/nvim/lazy/nvim-claude/

# For packer
ls -la ~/.local/share/nvim/site/pack/packer/start/nvim-claude/
```

You should see these directories:
- `lua/`
- `mcp-server/`
- `scripts/`
- `plugin/`

If `mcp-server/` is missing, the clone was incomplete.

#### Manual fix:

If automated installation fails, you can manually install:

```bash
# Navigate to your plugin directory (adjust path as needed)
cd ~/.local/share/nvim/lazy/nvim-claude/

# If mcp-server is missing, your clone might be shallow
# Convert to full clone:
git fetch --unshallow

# Or manually run the install script if it exists:
bash mcp-server/install.sh
```

### "nvr (neovim-remote) not found"

The plugin requires neovim-remote for hook integration:

```bash
# Install with pip
pip install neovim-remote

# Or with pipx (recommended)
pipx install neovim-remote

# Verify installation
which nvr
```

### Testing Your Installation

Run the included test script:

```bash
# From the plugin directory
nvim -l scripts/test-installation.lua
```

This will check:
- Plugin loading
- Directory structure  
- Dependencies
- MCP installation status

## Manual MCP Installation

If `:ClaudeInstallMCP` fails, you can install manually:

```bash
# Create virtual environment
python3 -m venv ~/.local/share/nvim/nvim-claude/mcp-env

# Activate it
source ~/.local/share/nvim/nvim-claude/mcp-env/bin/activate

# Install MCP
pip install fastmcp || pip install mcp

# Deactivate
deactivate
```

Then get the setup command with `:ClaudeShowMCPCommand`

## Getting Help

If you're still having issues:

1. Run `:ClaudeDebugInstall` and share the output
2. Check `:messages` for any error details
3. Look at the debug log with `:ClaudeViewLog`
4. Report issues at: https://github.com/zolinthecow/nvim-claude/issues

Include:
- Your Neovim version (`:version`)
- Your package manager (lazy.nvim, packer, etc.)
- The output of `:ClaudeDebugInstall`
- Any error messages