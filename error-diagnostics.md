# Error Diagnostics Integration for nvim-claude

## Overview

This document outlines the implementation plan for integrating LSP diagnostics with Claude Code, allowing Claude to see and automatically fix lint errors in edited files.

## Goals

1. **Automatic Error Detection**: Claude should be prevented from completing tasks when lint errors exist
2. **Self-Service Diagnostics**: Claude should be able to query and understand diagnostics
3. **Visual Mode Integration**: Users can send code selections with diagnostics to Claude
4. **Loop Prevention**: Ensure Claude doesn't get stuck trying to fix unfixable errors

## Built-in Loop Protection

Claude Code has built-in protection against infinite loops in Stop hooks through the `stop_hook_active` flag:

1. **First Stop Attempt**: Claude tries to stop → Stop hook runs → Can block with `decision: "block"`
2. **Claude Processes Block**: Claude sees the block reason and attempts to fix the issues
3. **Second Stop Attempt**: Claude tries to stop again → `stop_hook_active` is now true
4. **Automatic Allow**: The Stop hook still runs but Claude ignores any block decision when `stop_hook_active` is true

This means:
- Claude will only retry once after being blocked
- No need for complex attempt counting in basic implementations
- The system prevents infinite loops automatically

## Architecture

### Component Overview

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│  Claude Code    │────▶│  Stop Hook   │────▶│   Neovim    │
│                 │     │  Validator   │     │  (via nvr)  │
│                 │     └──────────────┘     └─────────────┘
│                 │              │                    │
│                 │              ▼                    ▼
│                 │     ┌──────────────┐     ┌─────────────┐
│                 │◀────│   Decision   │◀────│ Diagnostics │
│                 │     │  (block/ok)  │     │   Check     │
└─────────────────┘     └──────────────┘     └─────────────┘
        │
        ▼
┌─────────────────┐
│   MCP Server    │
│  (nvim-lsp)     │
└─────────────────┘
```

### Dynamic Server Resolution

The MCP server automatically connects to the current Neovim instance:

1. **Neovim Startup**: Creates unique server address (e.g., `/tmp/nvim.user/XXX/nvim.PID.0`)
2. **Address Tracking**: Saved to `.nvim-claude/nvim-server` in project root
3. **MCP Connection**: Server reads address from file and connects via `nvr`
4. **Local Scope**: Each project's MCP server connects to its own Neovim instance

```python
def get_nvim_server():
    # Check project-specific location first
    if os.path.exists('.nvim-claude/nvim-server'):
        return read_file('.nvim-claude/nvim-server')
    # Fall back to global location
    # Check environment variable
    # Default to common socket paths
```

## Implementation Phases

### Phase 1: Basic Stop Hook (MVP)

**Goal**: Block Claude from stopping when errors or warnings exist in edited files

#### 1.1 Stop Hook Script (`stop-hook-validator.sh`)

```bash
#!/bin/bash
# Simple validator that checks for errors in session files

INPUT=$(cat)

# Get diagnostic counts from Neovim
DIAGNOSTIC_JSON=$(nvr --remote-expr "require('nvim-claude.hooks').get_session_diagnostic_counts()")
ERROR_COUNT=$(echo "$DIAGNOSTIC_JSON" | jq '.errors')
WARNING_COUNT=$(echo "$DIAGNOSTIC_JSON" | jq '.warnings')
TOTAL_COUNT=$((ERROR_COUNT + WARNING_COUNT))

if [ "$TOTAL_COUNT" -gt 0 ]; then
    REASON="Found $ERROR_COUNT errors and $WARNING_COUNT warnings in edited files. "
    REASON="${REASON}Please fix these issues before completing. "
    REASON="${REASON}Check the diagnostics in the editor or use the nvim-lsp MCP server."
    
    cat <<EOF
{
    "decision": "block",
    "reason": "$REASON"
}
EOF
else
    echo '{"continue": true}'
fi
```

#### 1.2 Lua Support Functions

```lua
-- In hooks.lua
M.session_edited_files = {}

function M.post_tool_use_hook(file_path)
    -- Track edited files
    local relative_path = get_relative_path(file_path)
    M.session_edited_files[relative_path] = true
    
    -- ... existing code ...
end

function M.get_session_diagnostic_counts()
    local counts = { errors = 0, warnings = 0 }
    
    for file_path, _ in pairs(M.session_edited_files) do
        local full_path = vim.fn.getcwd() .. '/' .. file_path
        local bufnr = vim.fn.bufnr(full_path)
        
        if bufnr ~= -1 then
            local diagnostics = vim.diagnostic.get(bufnr)
            
            for _, diag in ipairs(diagnostics) do
                if diag.severity == vim.diagnostic.severity.ERROR then
                    counts.errors = counts.errors + 1
                elseif diag.severity == vim.diagnostic.severity.WARN then
                    counts.warnings = counts.warnings + 1
                end
            end
        end
    end
    
    return vim.json.encode(counts)
end
```

### Phase 2: MCP Server for Detailed Diagnostics

**Goal**: Give Claude tools to understand and fix specific errors

#### 2.1 Directory Structure

```
nvim-claude/
├── lua/nvim-claude/
│   └── mcp-bridge.lua         # Lua bridge for MCP server
├── mcp-server/
│   ├── nvim-lsp-server.py     # The MCP server
│   ├── requirements.txt       # Just: mcp
│   └── install.sh            # Installation script
```

#### 2.2 MCP Server Implementation (`mcp-server/nvim-lsp-server.py`)

```python
#!/usr/bin/env python3
import sys
import json
import subprocess
from typing import Dict, List, Optional

# Option 1: Using standard mcp package
try:
    from mcp.server.stdio import StdioServer
    from mcp.server import Server
except ImportError:
    # Option 2: Using fastmcp (simpler syntax)
    try:
        from fastmcp import FastMCP
    except ImportError:
        print("Error: mcp package not installed. Run :ClaudeInstallMCP", file=sys.stderr)
        sys.exit(1)

# Using FastMCP for simpler implementation
mcp = FastMCP("nvim-lsp")

@mcp.tool()
def get_diagnostics(file_paths: Optional[List[str]] = None) -> str:
    """Get LSP diagnostics for specific files or all buffers
    
    Args:
        file_paths: List of file paths to check. If None/empty, checks all open buffers.
                   Can also pass a single file as a string for backwards compatibility.
    
    Examples:
        get_diagnostics() - Get all diagnostics
        get_diagnostics("src/main.lua") - Single file
        get_diagnostics(["src/main.lua", "src/utils.lua"]) - Multiple files
    """
    # Handle backwards compatibility - single string to list
    if isinstance(file_paths, str):
        file_paths = [file_paths]
    
    # Escape paths for Lua
    paths_arg = json.dumps(file_paths or [])
    lua_expr = f"""require('nvim-claude.mcp-bridge').get_diagnostics({paths_arg})"""
    
    result = subprocess.run(['nvr', '--remote-expr', lua_expr], 
                          capture_output=True, text=True)
    if result.returncode != 0:
        return json.dumps({"error": result.stderr})
    return result.stdout

@mcp.tool()
def get_diagnostic_context(file_path: str, line: int) -> str:
    """Get code context around a specific diagnostic"""
    lua_expr = f"""require('nvim-claude.mcp-bridge').get_diagnostic_context('{file_path}', {line})"""
    result = subprocess.run(['nvr', '--remote-expr', lua_expr], 
                          capture_output=True, text=True)
    if result.returncode != 0:
        return json.dumps({"error": result.stderr})
    return result.stdout

@mcp.tool()
def get_diagnostic_summary() -> str:
    """Get a summary of all diagnostics across the project"""
    lua_expr = """require('nvim-claude.mcp-bridge').get_diagnostic_summary()"""
    result = subprocess.run(['nvr', '--remote-expr', lua_expr], 
                          capture_output=True, text=True)
    if result.returncode != 0:
        return json.dumps({"error": result.stderr})
    return result.stdout

@mcp.tool()
def get_session_diagnostics() -> str:
    """Get diagnostics only for files edited in the current Claude session"""
    lua_expr = """require('nvim-claude.mcp-bridge').get_session_diagnostics()"""
    result = subprocess.run(['nvr', '--remote-expr', lua_expr], 
                          capture_output=True, text=True)
    if result.returncode != 0:
        return json.dumps({"error": result.stderr})
    return result.stdout

if __name__ == "__main__":
    mcp.run()
```

#### 2.3 Lua Bridge (`lua/nvim-claude/mcp-bridge.lua`)

```lua
local M = {}

function M.get_diagnostics(file_paths)
  local diagnostics = {}
  
  -- Parse JSON array if string
  if type(file_paths) == 'string' then
    local ok, parsed = pcall(vim.json.decode, file_paths)
    file_paths = ok and parsed or {}
  end
  
  if not file_paths or #file_paths == 0 then
    -- Get all diagnostics
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' then
          local diags = vim.diagnostic.get(buf)
          if #diags > 0 then
            diagnostics[vim.fn.fnamemodify(name, ':~:.')] = M._format_diagnostics(diags)
          end
        end
      end
    end
  else
    -- Get diagnostics for specific files
    for _, file_path in ipairs(file_paths) do
      -- Try exact path first
      local bufnr = vim.fn.bufnr(file_path)
      
      -- If not found, try as relative path from cwd
      if bufnr == -1 then
        local full_path = vim.fn.getcwd() .. '/' .. file_path
        bufnr = vim.fn.bufnr(full_path)
      end
      
      if bufnr ~= -1 then
        local diags = vim.diagnostic.get(bufnr)
        if #diags > 0 then
          local display_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
          diagnostics[display_path] = M._format_diagnostics(diags)
        end
      end
    end
  end
  
  return vim.json.encode(diagnostics)
end

function M.get_diagnostic_context(file_path, line)
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr == -1 then
    return vim.json.encode({error = "File not open"})
  end
  
  -- Get diagnostics for the specific line
  local diags = vim.diagnostic.get(bufnr, {lnum = line - 1})
  
  -- Get surrounding code context
  local start_line = math.max(0, line - 6)
  local end_line = line + 5
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  
  return vim.json.encode({
    diagnostics = M._format_diagnostics(diags),
    context = {
      lines = lines,
      start_line = start_line + 1,
      target_line = line,
    },
    filetype = vim.bo[bufnr].filetype,
  })
end

function M.get_diagnostic_summary()
  local summary = {
    total_errors = 0,
    total_warnings = 0,
    files_with_issues = {},
  }
  
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' then
        local diags = vim.diagnostic.get(buf)
        local file_errors = 0
        local file_warnings = 0
        
        for _, d in ipairs(diags) do
          if d.severity == vim.diagnostic.severity.ERROR then
            file_errors = file_errors + 1
            summary.total_errors = summary.total_errors + 1
          elseif d.severity == vim.diagnostic.severity.WARN then
            file_warnings = file_warnings + 1
            summary.total_warnings = summary.total_warnings + 1
          end
        end
        
        if file_errors > 0 or file_warnings > 0 then
          table.insert(summary.files_with_issues, {
            file = vim.fn.fnamemodify(name, ':~:.'),
            errors = file_errors,
            warnings = file_warnings,
          })
        end
      end
    end
  end
  
  return vim.json.encode(summary)
end

function M.get_session_diagnostics()
  local hooks = require('nvim-claude.hooks')
  local session_files = {}
  
  -- Get list of files edited in current session
  for file_path, _ in pairs(hooks.session_edited_files or {}) do
    table.insert(session_files, file_path)
  end
  
  -- Use existing get_diagnostics function with session files
  return M.get_diagnostics(session_files)
end

function M._format_diagnostics(diags)
  local formatted = {}
  for _, d in ipairs(diags) do
    table.insert(formatted, {
      line = d.lnum + 1,
      column = d.col + 1,
      severity = vim.diagnostic.severity[d.severity],
      message = d.message,
      source = d.source or 'lsp'
    })
  end
  return formatted
end

return M
```

#### 2.4 Update Stop Hook Message

```bash
# In stop-hook-validator.sh
REASON="Found $ERROR_COUNT errors and $WARNING_COUNT warnings in edited files. "
REASON="${REASON}Use 'mcp__nvim-lsp__get_session_diagnostics' to see details."
```

### Phase 3: Advanced Features

**Goal**: Add visual mode integration and better UX

#### 3.1 Session Cleanup

Since Claude Code handles loop protection automatically, we just need to clean up after each session:

```lua
-- Reset session tracking after completion
function M.reset_session_tracking()
    M.session_edited_files = {}
    -- Called when Claude successfully completes (hook returns continue: true)
end
```

#### 3.2 Visual Mode Command (like `<leader>cv` but with diagnostics)

```lua
-- In commands.lua
vim.api.nvim_create_user_command('ClaudeSendWithDiagnostics', function(args)
    local lines = vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
    local code = table.concat(lines, '\n')
    local file = vim.fn.expand('%:~:.')
    
    -- Get diagnostics for selected range
    local diagnostics = vim.diagnostic.get(0, {
        lnum = {args.line1 - 1, args.line2 - 1}
    })
    
    -- Format message
    local message = string.format([[
I have a code snippet with LSP diagnostics that need to be fixed:

File: %s
Lines: %d-%d

```%s
%s
```

LSP Diagnostics:
%s

Please help me fix these issues.]], 
        file, args.line1, args.line2, 
        vim.bo.filetype, code,
        format_diagnostics_list(diagnostics))
    
    -- Send to Claude via tmux
    require('nvim-claude.tmux').send_selection_to_claude(nil, message)
end, { range = true })

-- Helper function
function format_diagnostics_list(diagnostics)
    if #diagnostics == 0 then
        return "No diagnostics in selected range"
    end
    
    local lines = {}
    for _, d in ipairs(diagnostics) do
        local severity = vim.diagnostic.severity[d.severity]
        table.insert(lines, string.format(
            "- Line %d, Col %d [%s]: %s", 
            d.lnum + 1, d.col + 1, severity, d.message
        ))
    end
    return table.concat(lines, '\n')
end
```

#### 3.3 Keybinding

```lua
-- In mappings.lua, add to visual mode mappings
map('v', prefix .. 'd', ':ClaudeSendWithDiagnostics<CR>', 'Send selection with diagnostics')

-- So users can use:
-- 1. Select code in visual mode
-- 2. Press <leader>cd
-- 3. Claude receives the code + all diagnostics for that range
```

## Configuration

### Hook Installation

Update `install_hooks` to add Stop hook:

```lua
-- Add Stop hook configuration
existing_settings.hooks.Stop = existing_settings.hooks.Stop or {}
add_hook_to_section(existing_settings.hooks.Stop, stop_validator_command)
```

### CLAUDE.md Instructions

```markdown
## LSP Diagnostics

When you edit files, the system will check for lint errors and warnings before allowing you to complete.
If any issues are found, you'll be asked to fix them. You get one retry attempt - if you still can't fix them,
you'll be allowed to complete.

Use the nvim-lsp MCP server to get diagnostics:
- `get_diagnostics()` - Get all diagnostics across all open buffers
- `get_diagnostics("src/main.lua")` - Get diagnostics for a single file
- `get_diagnostics(["src/main.lua", "src/utils.lua"])` - Get diagnostics for multiple files
- `get_session_diagnostics()` - Get diagnostics only for files you edited in this session
- `get_diagnostic_context(file_path, line)` - Get code context around a specific diagnostic
- `get_diagnostic_summary()` - Get a summary of all errors/warnings with file counts

Best practices:
1. Always fix errors before warnings
2. Check diagnostics proactively after making changes
3. If you can't fix an issue on the second attempt, add a comment explaining why
```

## Example Workflow

### Claude Gets Blocked on Stop
```
Claude: "I've finished implementing the feature."
[Tries to stop]

Stop Hook: "Found 3 errors and 5 warnings in edited files. 
Use 'mcp__nvim-lsp__get_session_diagnostics' to see details."

Claude: "Let me check the diagnostics for the files I edited..."
[Uses get_session_diagnostics()]
[Gets diagnostics only for src/main.lua and src/utils.lua that were edited]
[Fixes the issues]
[Tries to stop again - succeeds]
```

## Testing Plan

1. **Unit Tests**
   - Test diagnostic counting logic (errors + warnings)
   - Test file tracking across sessions
   - Test session cleanup
   - Test multiple file path handling

2. **Integration Tests**
   - Test Stop hook blocking/allowing
   - Test MCP server responses with multiple files
   - Test visual mode command

3. **End-to-End Tests**
   - Claude edits multiple files with errors/warnings → blocked → fixes issues → allowed
   - Claude blocked once → tries to stop again → allowed (built-in protection)
   - User sends code with diagnostics → Claude receives formatted message
   - Test file path resolution (relative vs absolute paths)

## Installation & Setup

### Auto-Installation with lazy.nvim

```lua
{
  'zolinthecow/nvim-claude',
  build = ':ClaudeInstallMCP',  -- Auto-install MCP dependencies
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
  config = function()
    require('nvim-claude').setup({
      mcp = {
        auto_install = true,  -- Auto-install on startup
      }
    })
  end
}
```

### Manual Installation

1. **Install Prerequisites**:
   ```bash
   # Install Python 3 (if not already installed)
   # Install nvr
   pip install neovim-remote
   ```

2. **Install MCP Server**:
   ```bash
   cd ~/.local/share/nvim/lazy/nvim-claude/mcp-server
   bash install.sh
   ```

3. **Add to Claude Code (Local Scope)**:
   ```bash
   # The install script will show you this command:
   claude mcp add nvim-lsp -s local ~/.local/share/nvim/nvim-claude/mcp-env/bin/python /path/to/nvim-lsp-server.py
   ```
   
   **Why Local Scope?**
   - Each Neovim instance has a unique server address
   - Local scope ensures MCP server connects to the project's Neovim
   - Server automatically finds the current Neovim instance via `.nvim-claude/nvim-server`

### Installation Script (`mcp-server/install.sh`)

```bash
#!/bin/bash
set -e

echo "🔧 Setting up nvim-claude MCP server..."

# Check dependencies
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: Python 3 is required but not installed."
    exit 1
fi

if ! command -v nvr &> /dev/null; then
    echo "❌ Error: nvr (neovim-remote) is required but not installed."
    echo "   Install with: pip install neovim-remote"
    exit 1
fi

# Setup paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
VENV_PATH="$HOME/.local/share/nvim/nvim-claude/mcp-env"

# Create virtual environment
echo "📦 Creating Python virtual environment..."
python3 -m venv "$VENV_PATH"

# Install MCP (try fastmcp first, fallback to mcp)
echo "📥 Installing MCP package..."
"$VENV_PATH/bin/pip" install --quiet --upgrade pip

if "$VENV_PATH/bin/pip" install --quiet fastmcp; then
    echo "fastmcp" > "$SCRIPT_DIR/requirements.txt"
    echo "✨ Using FastMCP (recommended)"
else
    echo "⚠️  FastMCP not available, using standard mcp package"
    "$VENV_PATH/bin/pip" install --quiet mcp
    echo "mcp" > "$SCRIPT_DIR/requirements.txt"
fi

echo "✅ MCP server installed successfully!"
echo ""
echo "To add to Claude Code, run:"
echo "  claude mcp add nvim-lsp $VENV_PATH/bin/python $SCRIPT_DIR/nvim-lsp-server.py"
```

### Neovim Setup Command

```lua
-- In commands.lua
vim.api.nvim_create_user_command('ClaudeInstallMCP', function()
  local plugin_path = debug.getinfo(1, 'S').source:sub(2):match('(.*/)')
  local install_script = plugin_path .. '../../mcp-server/install.sh'
  
  local function on_exit(job_id, code, event)
    if code == 0 then
      vim.notify('✅ MCP server installed successfully!', vim.log.levels.INFO)
      vim.notify('Run "claude mcp list" to verify installation', vim.log.levels.INFO)
    else
      vim.notify('❌ MCP installation failed. Check :messages for details', vim.log.levels.ERROR)
    end
  end
  
  vim.notify('Installing MCP server dependencies...', vim.log.levels.INFO)
  vim.fn.jobstart({'bash', install_script}, {
    on_exit = on_exit,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then print(line) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then vim.notify(line, vim.log.levels.WARN) end
      end
    end,
  })
end, { desc = 'Install Claude MCP server dependencies' })
```

## Open Questions

1. **Attempt Scope**: Should we use the built-in protection or add custom attempt tracking?
2. **Diagnostic Sources**: Just LSP or include other linters?
3. **Warning Threshold**: Should we allow completion if only warnings remain after one retry?
4. **MCP Package**: Should we use the official `mcp` package or `fastmcp` for simpler syntax?

## Next Steps

1. [ ] Implement Phase 1 MVP (Stop hook)
2. [ ] Create MCP server and installation scripts
3. [ ] Test installation process on fresh system
4. [ ] Update README with installation instructions
5. [ ] Test with real Claude Code sessions
6. [ ] Implement Phase 3 (visual mode command)