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
_headless_owned = False
_headless_lock = threading.Lock()

def ensure_headless_nvim():
    """Ensure a headless Neovim instance is running."""
    global _headless_process, _headless_socket, _headless_owned

    with _headless_lock:
        process_alive = _headless_process and _headless_process.poll() is None
        if process_alive:
            if (_headless_socket and os.path.exists(_headless_socket)
                    and test_socket_responsive(_headless_socket)):
                return _headless_socket
            cleanup_headless()
        elif _headless_owned:
            cleanup_headless()

        cwd = os.getcwd()
        project_hash = hashlib.sha256(cwd.encode()).hexdigest()[:8]
        _headless_socket = (
            f"/tmp/nvim-claude-headless-{project_hash}-{os.getpid()}.sock"
        )
        if os.path.exists(_headless_socket):
            try:
                os.unlink(_headless_socket)
            except OSError:
                pass

        config_dir = os.path.expanduser("~/.config/nvim")
        user_init = os.path.join(config_dir, "init.lua")
        nvim_cmd = [
            "nvim", "--headless", "--listen", _headless_socket,
            "--cmd", "let g:headless_mode=1",
            "-u", user_init,
        ]

        try:
            _headless_process = subprocess.Popen(
                nvim_cmd,
                cwd=cwd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                preexec_fn=os.setsid if sys.platform != 'win32' else None
            )
            _headless_owned = True

            for _ in range(50):
                if os.path.exists(_headless_socket):
                    time.sleep(0.2)
                    break
                time.sleep(0.1)
            else:
                cleanup_headless()
                raise RuntimeError("Headless Neovim failed to create socket")

            atexit.register(cleanup_headless)
            return _headless_socket
        except Exception as e:
            cleanup_headless()
            raise RuntimeError(f"Failed to start headless Neovim: {e}")


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


def cleanup_headless():
    """Clean up the headless Neovim instance and LSP servers."""
    global _headless_process, _headless_socket, _headless_owned

    if not _headless_owned:
        _headless_process = None
        _headless_socket = None
        return
    
    process_alive = _headless_process and _headless_process.poll() is None

    # First, try to gracefully stop LSP servers.
    if process_alive and _headless_socket and os.path.exists(_headless_socket):
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
    _headless_owned = False


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
    
    # pynvim accepts Lua varargs. Passing the Python list as one value makes
    # two-argument methods receive a List followed by nil.
    lua_expr = "return require('{LUA_MODULE}').{function_name}(...)"
    result = nvim.exec_lua(lua_expr, *args)
    
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
