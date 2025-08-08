#!/usr/bin/env python3
"""
MCP -> Neovim LSP bridge (nvim-lsp)

This module exposes a small set of MCP tools that talk to a headless Neovim
instance running in the background specifically for LSP diagnostics.

The headless instance:
- Runs the same LSP servers as the user's main Neovim  
- Processes files independently without affecting the user's UI
- Provides fresh diagnostics synchronously via subprocess calls
"""

import os
import sys
import json
import subprocess
import time
import atexit
import signal
import hashlib
from typing import Iterable, Optional, Union

# Check pynvim is available (for subprocess calls)
try:
    subprocess.run([sys.executable, '-c', 'import pynvim'], check=True, capture_output=True)
except subprocess.CalledProcessError:
    print("Error: pynvim is not installed in the MCP environment", file=sys.stderr)
    print("Please add pynvim to mcp-server/requirements.txt and reinstall", file=sys.stderr)
    sys.exit(1)

for key in ("FASTMCP_LOG_LEVEL", "LOG_LEVEL"):
    if key in os.environ:
        os.environ[key] = os.environ[key].upper()
    else:
        # Only set a default if nothing supplied
        os.environ[key] = "INFO"

# ---------------------------------------------------------------------------
# MCP setup -----------------------------------------------------------------
# ---------------------------------------------------------------------------
from fastmcp import FastMCP  # type: ignore

mcp = FastMCP("nvim-lsp")  # type: ignore

# The Lua module we call inside Neovim
LUA_MODULE = "nvim-claude.mcp-bridge"


# ---------------------------------------------------------------------------
# Headless Neovim management (subprocess only) -----------------------------
# ---------------------------------------------------------------------------

# Global state for headless instance
_headless_process = None
_headless_socket = None

def ensure_headless_nvim():
    """Ensure a headless Neovim instance is running."""
    global _headless_process, _headless_socket
    
    if _headless_socket and os.path.exists(_headless_socket):
        # Check if process is still alive
        if _headless_process and _headless_process.poll() is None:
            return _headless_socket
    
    # Start new headless instance
    cwd = os.getcwd()
    project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
    _headless_socket = f"/tmp/nvim-claude-headless-{project_hash}.sock"
    
    # Remove old socket if it exists
    if os.path.exists(_headless_socket):
        try:
            os.unlink(_headless_socket)
        except:
            pass
    
    # Build Neovim command
    nvim_cmd = ["nvim", "--headless", "--listen", _headless_socket]
    
    # Create init file that loads user config properly
    script_path = os.path.abspath(__file__)
    mcp_server_dir = os.path.dirname(script_path)  # .../nvim-claude/mcp-server
    nvim_claude_dir = os.path.dirname(mcp_server_dir)  # .../nvim-claude
    
    config_dir = os.path.expanduser("~/.config/nvim")
    user_init = os.path.join(config_dir, "init.lua")
    
    # Create an init file that loads the user's full config
    init_content = f"""
-- Init file for headless LSP server
-- First add the nvim-claude plugin to runtimepath
vim.opt.runtimepath:append('{nvim_claude_dir}')

-- Load the user's full config if it exists
-- This will load lazy.nvim and all plugins including LSP
local user_init = '{user_init}'
if vim.fn.filereadable(user_init) == 1 then
  -- Set headless flag so plugins can adapt if needed
  vim.g.headless_mode = true
  
  -- Source the user's init.lua
  dofile(user_init)
  
  -- Wait a bit for lazy.nvim to load plugins
  vim.wait(1000, function()
    return pcall(require, 'lspconfig')
  end, 100)
  
  -- Ensure LSP diagnostics are enabled
  vim.diagnostic.config({{
    virtual_text = true,
    signs = true,
    underline = true,
    update_in_insert = false,
    severity_sort = false,
  }})
else
  -- Fallback: try to set up minimal LSP
  local ok_lspconfig, lspconfig = pcall(require, 'lspconfig')
  if ok_lspconfig then
    -- Basic lua_ls setup
    pcall(function()
      lspconfig.lua_ls.setup({{
        settings = {{
          Lua = {{
            runtime = {{ version = 'LuaJIT' }},
            diagnostics = {{ globals = {{ 'vim' }} }},
            workspace = {{
              library = vim.api.nvim_get_runtime_file("", true),
              checkThirdParty = false,
            }},
          }},
        }},
      }})
    end)
  end
  
  -- Enable diagnostics
  vim.diagnostic.config({{
    virtual_text = true,
    signs = true,
    underline = true,
    update_in_insert = false,
    severity_sort = false,
  }})
end
"""
    
    init_file = f"/tmp/nvim-claude-headless-{project_hash}-init.lua"
    with open(init_file, 'w') as f:
        f.write(init_content)
    
    nvim_cmd.extend(["-u", init_file])
    
    # Start the headless Neovim process
    try:
        _headless_process = subprocess.Popen(
            nvim_cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid if sys.platform != 'win32' else None
        )
        
        # Wait for socket to be created
        for _ in range(50):  # 5 seconds timeout
            if os.path.exists(_headless_socket):
                break
            time.sleep(0.1)
        else:
            cleanup_headless()
            raise RuntimeError("Headless Neovim failed to create socket")
        
        # Register cleanup
        atexit.register(cleanup_headless)
        
        return _headless_socket
        
    except Exception as e:
        cleanup_headless()
        raise RuntimeError(f"Failed to start headless Neovim: {e}")


def cleanup_headless():
    """Clean up the headless Neovim instance."""
    global _headless_process, _headless_socket
    
    if _headless_process:
        try:
            _headless_process.terminate()
            _headless_process.wait(timeout=2)
        except:
            try:
                if sys.platform != 'win32':
                    os.killpg(os.getpgid(_headless_process.pid), signal.SIGKILL)
                else:
                    _headless_process.kill()
            except:
                pass
        _headless_process = None
    
    if _headless_socket and os.path.exists(_headless_socket):
        try:
            os.unlink(_headless_socket)
        except:
            pass
    _headless_socket = None


def call_headless_lua(function_name: str, *args):
    """Call a Lua function in the headless Neovim via subprocess."""
    socket_path = ensure_headless_nvim()
    
    # Base64 encode the arguments to avoid escaping issues in the shell
    import base64
    args_json = json.dumps(list(args))
    args_b64 = base64.b64encode(args_json.encode('utf-8')).decode('ascii')
    
    # Create a Python script to run in subprocess
    script = f"""
import json
import pynvim
import base64

try:
    nvim = pynvim.attach('socket', path='{socket_path}')
    
    # Decode the base64 arguments
    args_b64 = '{args_b64}'
    args_json = base64.b64decode(args_b64).decode('utf-8')
    args = json.loads(args_json)
    
    # Call the Lua function directly
    # Unpack single argument to avoid double nesting
    if len(args) == 1:
        lua_expr = "return require('{LUA_MODULE}').{function_name}(...)"
        result = nvim.exec_lua(lua_expr, args[0] if isinstance(args[0], list) else [args[0]])
    else:
        lua_expr = "return require('{LUA_MODULE}').{function_name}(...)"
        result = nvim.exec_lua(lua_expr, args)
    
    # Convert result to JSON string if needed
    if isinstance(result, str):
        print(result)
    else:
        print(json.dumps(result))
    
    nvim.close()
    
except Exception as e:
    error_dict = {{"error": "Failed to call Neovim: " + str(e)}}
    print(json.dumps(error_dict))
"""
    
    try:
        # Run the script in a subprocess
        result = subprocess.run(
            [sys.executable, '-c', script],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        else:
            error_output = result.stderr.strip() or "No output from subprocess"
            return json.dumps({"error": error_output})
            
    except subprocess.TimeoutExpired:
        return json.dumps({"error": "Timeout waiting for Neovim response"})
    except Exception as e:
        return json.dumps({"error": f"Subprocess execution failed: {str(e)}"})


# ---------------------------------------------------------------------------
# Public MCP tools -----------------------------------------------------------
# ---------------------------------------------------------------------------
@mcp.tool()
def get_diagnostics(file_paths: Optional[Union[str, Iterable[str]]] = None) -> str:
    """Get LSP diagnostics for specific files or all buffers.

    Args:
        file_paths: List of file paths to check. If None/empty, checks all open buffers.
                    Accepts a single string, a JSON-encoded list string, or an iterable.
    """
    # Normalize file_paths input
    if isinstance(file_paths, str):
        try:
            decoded = json.loads(file_paths)
            if isinstance(decoded, list):
                file_paths = decoded
            elif isinstance(decoded, str):
                file_paths = [decoded]
            else:
                file_paths = []
        except json.JSONDecodeError:
            file_paths = [file_paths]
    elif file_paths is None:
        file_paths = []
    elif not isinstance(file_paths, list):
        try:
            file_paths = list(file_paths)  # type: ignore[arg-type]
        except TypeError:
            file_paths = []

    # Use headless Neovim for diagnostics
    # Pass file_paths directly as a single argument (it's already a list)
    return call_headless_lua("get_diagnostics", file_paths)


@mcp.tool()
def get_diagnostic_context(file_path: str, line: int) -> str:
    """Get code context around a specific diagnostic."""
    return call_headless_lua("get_diagnostic_context", file_path, line)


@mcp.tool()
def get_diagnostic_summary() -> str:
    """Get a summary of all diagnostics across the project."""
    return call_headless_lua("get_diagnostic_summary")


@mcp.tool()
def get_session_diagnostics() -> str:
    """Get diagnostics only for files edited in the current Claude session.
    
    Note: This reads the session files from the user's main Neovim instance
    but processes them in the headless instance.
    """
    # First, get the list of session files from the user's Neovim
    cwd = os.getcwd()
    project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
    
    # Try to get session files from the main instance's server file
    session_files = []
    
    # Try connecting to main instance briefly just to get session files
    runtime_dir = os.environ.get('XDG_RUNTIME_DIR', '/tmp')
    server_file = os.path.join(runtime_dir, f"nvim-claude-{project_hash}-server")
    if not os.path.exists(server_file):
        server_file = f"/tmp/nvim-claude-{project_hash}-server"
    
    if os.path.exists(server_file):
        with open(server_file, 'r') as f:
            main_socket = f.read().strip()
        
        # Use subprocess to get session files
        script = f"""
import json
import pynvim

try:
    nvim = pynvim.attach('socket', path='{main_socket}')
    files = nvim.exec_lua('''
        local hooks = require('nvim-claude.hooks')
        local files = {{}}
        for file_path, _ in pairs(hooks.session_edited_files or {{}}) do
            if vim.fn.filereadable(file_path) == 1 then
                table.insert(files, file_path)
            end
        end
        return files
    ''')
    nvim.close()
    print(json.dumps(files))
except:
    print('[]')
"""
        
        try:
            result = subprocess.run(
                [sys.executable, '-c', script],
                capture_output=True,
                text=True,
                timeout=2.0
            )
            if result.returncode == 0:
                session_files = json.loads(result.stdout.strip() or '[]')
        except:
            pass
    
    # Now check diagnostics for session files in headless instance
    if session_files:
        return call_headless_lua("get_diagnostics", session_files)
    else:
        return json.dumps([])


# ---------------------------------------------------------------------------
# Cleanup on exit -----------------------------------------------------------
# ---------------------------------------------------------------------------
# Handle signals for cleanup
def signal_handler(sig, frame):
    cleanup_headless()
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


# ---------------------------------------------------------------------------
# Main ----------------------------------------------------------------------
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    try:
        mcp.run()
    finally:
        cleanup_headless()