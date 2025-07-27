# Quick Fix for "MCP install script not found"

If you're getting this error, here's how to fix it quickly:

## Option 1: Re-install the plugin (Recommended)

For lazy.nvim users:

1. Open Neovim and run `:Lazy`
2. Find `nvim-claude` in the list
3. Press `x` to clean/remove it
4. Press `I` to install it fresh
5. Try `:ClaudeInstallMCP` again

## Option 2: Check what's missing

Run this command in Neovim:
```vim
:ClaudeDebugInstall
```

This will show you:
- Where the plugin is installed
- What directories are missing
- Current MCP installation status

## Option 3: Manual check

Check if the mcp-server directory exists:
```bash
# For lazy.nvim
ls ~/.local/share/nvim/lazy/nvim-claude/mcp-server/

# Should show: install.sh, nvim-lsp-server.py, etc.
```

If it's missing, the plugin wasn't fully downloaded.

## Option 4: Manual fix

If the directory is missing:

```bash
cd ~/.local/share/nvim/lazy/nvim-claude
git status  # Check if it's a git repo
git pull    # Update to get all files
```

## Option 5: Test installation

Save this as `test.vim` and run `nvim -u test.vim`:

```vim
set runtimepath+=~/.local/share/nvim/lazy/nvim-claude
lua require('nvim-claude').setup({})
ClaudeDebugInstall
```

## Still having issues?

1. Share the output of `:ClaudeDebugInstall`
2. Check `:messages` for any errors
3. Let me know which package manager you're using (lazy.nvim, packer, etc.)

The issue is usually that lazy.nvim didn't download the complete plugin. Re-installing typically fixes it.