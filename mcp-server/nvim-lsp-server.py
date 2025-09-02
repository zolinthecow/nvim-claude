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
import threading
import fcntl
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
LUA_MODULE = "nvim-claude.lsp_mcp.bridge"


# ---------------------------------------------------------------------------
# Headless Neovim management (subprocess only) -----------------------------
# ---------------------------------------------------------------------------

# Global state for headless instance
_headless_process = None
_headless_socket = None
_headless_lock = threading.Lock()
_last_cleanup_time = 0

def ensure_headless_nvim():
    """Ensure a headless Neovim instance is running."""
    global _headless_process, _headless_socket, _last_cleanup_time
    
    with _headless_lock:
        # Periodic cleanup check (every 5 minutes)
        current_time = time.time()
        if current_time - _last_cleanup_time > 300:
            cleanup_orphaned_processes()
            _last_cleanup_time = current_time
        
        # Check if we have a valid running instance
        if _headless_socket and os.path.exists(_headless_socket):
            # Verify process is alive and responsive
            if _headless_process and _headless_process.poll() is None:
                # Test if socket is actually responsive
                if test_socket_responsive(_headless_socket):
                    return _headless_socket
                else:
                    # Socket exists but not responsive, clean it up
                    cleanup_headless()
        
        # Start new headless instance
        cwd = os.getcwd()
        project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
        _headless_socket = f"/tmp/nvim-claude-headless-{project_hash}.sock"
        
        # Use file locking to prevent race conditions
        lock_file = f"/tmp/nvim-claude-headless-{project_hash}.lock"
        try:
            with open(lock_file, 'w') as f:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                
                # Double-check socket doesn't exist now that we have the lock
                if os.path.exists(_headless_socket) and test_socket_responsive(_headless_socket):
                    return _headless_socket
                
                # Remove old socket if it exists
                if os.path.exists(_headless_socket):
                    try:
                        os.unlink(_headless_socket)
                    except:
                        pass
                
                # Build Neovim command - use simple approach that works
                config_dir = os.path.expanduser("~/.config/nvim")
                user_init = os.path.join(config_dir, "init.lua")
                
                nvim_cmd = [
                    "nvim", "--headless", "--listen", _headless_socket,
                    "-u", user_init,
                    "-c", "let g:headless_mode=1"
                ]
                
                # Start the headless Neovim process in the project directory
                try:
                    _headless_process = subprocess.Popen(
                        nvim_cmd,
                        cwd=cwd,  # Start in the project directory for proper LSP context
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        preexec_fn=os.setsid if sys.platform != 'win32' else None
                    )
                    
                    # Wait for socket to be created
                    for _ in range(50):  # 5 seconds timeout
                        if os.path.exists(_headless_socket):
                            time.sleep(0.2)  # Give it a moment to fully initialize
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
        except (IOError, OSError):
            # Another process has the lock, wait and retry
            time.sleep(0.5)
            return ensure_headless_nvim()


def test_socket_responsive(socket_path):
    """Test if a Neovim socket is responsive."""
    try:
        script = f"""
import pynvim
import sys
try:
    nvim = pynvim.attach('socket', path='{socket_path}')
    nvim.command('echo "test"')
    nvim.close()
    print("OK")
except:
    sys.exit(1)
"""
        result = subprocess.run(
            [sys.executable, '-c', script],
            capture_output=True,
            text=True,
            timeout=1.0
        )
        return result.returncode == 0 and "OK" in result.stdout
    except:
        return False


def cleanup_orphaned_processes():
    """Clean up orphaned headless Neovim processes for THIS project only."""
    try:
        # Get current project hash to target only this project's processes
        cwd = os.getcwd()
        project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
        project_socket_pattern = f'/tmp/nvim-claude-headless-{project_hash}.sock'
        
        # Find headless Neovim processes for this specific project
        result = subprocess.run(
            ['pgrep', '-f', f'nvim --headless --listen {project_socket_pattern}'],
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            pids = result.stdout.strip().split('\n')
            current_pid = _headless_process.pid if _headless_process else None
            
            for pid_str in pids:
                try:
                    pid = int(pid_str)
                    # Don't kill our current process, but clean up any others for this project
                    if pid != current_pid:
                        # Double-check this process is actually using our project's socket
                        proc_check = subprocess.run(
                            ['ps', '-p', str(pid), '-o', 'args='],
                            capture_output=True,
                            text=True
                        )
                        if proc_check.returncode == 0 and project_socket_pattern in proc_check.stdout:
                            os.kill(pid, signal.SIGTERM)
                except (ValueError, ProcessLookupError):
                    pass
    except:
        pass


def cleanup_headless():
    """Clean up the headless Neovim instance and LSP servers."""
    global _headless_process, _headless_socket
    
    # First, try to gracefully stop LSP servers
    if _headless_socket and os.path.exists(_headless_socket):
        try:
            script = f"""
import pynvim
try:
    nvim = pynvim.attach('socket', path='{_headless_socket}')
    # Stop all LSP clients before exiting
    nvim.exec_lua('''
        for _, client in pairs(vim.lsp.get_clients()) do
            client.stop()
        end
    ''')
    nvim.command('qa!')
    nvim.close()
except:
    pass
"""
            subprocess.run(
                [sys.executable, '-c', script],
                capture_output=True,
                timeout=2.0
            )
        except:
            pass
    
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
        # 5 second timeout should be sufficient now that we trigger push events
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
        file_paths: MUST be a JSON array of file paths, e.g. ["path/to/file1.ts", "path/to/file2.js"]
                   If None/empty array, checks all open buffers.
                   IMPORTANT: Always pass as a JSON array, even for single files: ["single_file.ts"]
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
    """Get code context around a specific diagnostic.
    
    Args:
        file_path: Full path to the file containing the diagnostic
        line: Line number of the diagnostic (1-indexed)
    """
    return call_headless_lua("get_diagnostic_context", file_path, line)


@mcp.tool()
def get_diagnostic_summary() -> str:
    """Get a summary of all diagnostics across the project."""
    return call_headless_lua("get_diagnostic_summary")


@mcp.tool()
def get_session_diagnostics() -> str:
    """Get diagnostics only for files edited this turn (headless-only)."""
    return call_headless_lua("get_session_diagnostics")


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
