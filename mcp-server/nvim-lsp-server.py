#!/usr/bin/env python3
"""
MCP -> Neovim LSP bridge (nvim-lsp)

This module exposes a small set of MCP tools that talk to a running Neovim
instance (found via a few heuristic paths) using `nvr --remote-expr`.

**Quoting strategy**
--------------------
We construct Vimscript expressions of the form:

    luaeval('require("nvim-claude.mcp-bridge").fn_name(...)')

Key points:
- The *outer* Vimscript string passed to `luaeval()` is **single-quoted**. That
  means we do **not** need to escape the many double quotes used inside the Lua
  chunk.
- All Lua string arguments (e.g., file paths) are wrapped in **double quotes**
  and escaped for Lua by replacing `\` -> `\\` and `"` -> `\"`.
- Because we call `subprocess.run([...])` **without a shell**, we do not need to
  perform shell quoting. The Python string is passed as-is to Neovim through
  `nvr`.

This greatly simplifies the escaping layer-cake that previously led to errors
like:

    No valid expression: luaeval("require(\"nvim-claude.mcp-bridge\").get_diagnostics({...})")

If you ever hit truly pathological file names (embedded newlines, control chars,
etc.), the next step would be to pass JSON and decode inside Lua; see the note at
the bottom of the file.
"""

import os
import sys
import json
import subprocess
from typing import Iterable, Optional, Union, List, Any

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
# Utility: Locate the Neovim server address ---------------------------------
# ---------------------------------------------------------------------------
def get_nvim_server() -> str:
    """Get the current Neovim server address.

    Search order:
    1. NVIM environment variable (if running inside Neovim terminal).
    2. Temp directory server file based on project root hash.
    3. Project-local .nvim-claude/nvim-server (deprecated).
    4. Global path under ~/.local/share/nvim/nvim-claude/nvim-server (deprecated).
    5. NVIM_SERVER environment variable.
    6. /tmp/nvimsocket (common default).
    """
    # If set in NVIM environment (running in Neovim terminal), use that
    if "NVIM" in os.environ:
        return os.environ["NVIM"]

    # Try to find server file in temp directory based on project root
    cwd = os.getcwd()
    import subprocess
    try:
        # Try to get git root
        result = subprocess.run(['git', 'rev-parse', '--show-toplevel'], 
                                capture_output=True, text=True, cwd=cwd)
        if result.returncode == 0:
            project_root = result.stdout.strip()
            # Generate the same hash as Neovim to find the server file
            import hashlib
            key_hash = hashlib.sha256(project_root.encode()).hexdigest()
            temp_dir = os.environ.get('XDG_RUNTIME_DIR', '/tmp')
            server_file = f"{temp_dir}/nvim-claude-{key_hash[:8]}-server"
            if os.path.exists(server_file):
                with open(server_file, "r", encoding="utf-8") as f:
                    return f.read().strip()
    except:
        pass

    # Project-specific location (relative) - deprecated but check for compatibility
    rel_project_path = os.path.join(".nvim-claude", "nvim-server")
    if os.path.exists(rel_project_path):
        with open(rel_project_path, "r", encoding="utf-8") as f:
            return f.read().strip()

    # Project-specific via cwd absolute path - deprecated
    cwd_plugin_path = os.path.join(os.getcwd(), ".nvim-claude", "nvim-server")
    if os.path.exists(cwd_plugin_path):
        with open(cwd_plugin_path, "r", encoding="utf-8") as f:
            return f.read().strip()

    # Global location - deprecated
    global_path = os.path.expanduser("~/.local/share/nvim/nvim-claude/nvim-server")
    if os.path.exists(global_path):
        with open(global_path, "r", encoding="utf-8") as f:
            return f.read().strip()

    # Environment variable
    if "NVIM_SERVER" in os.environ:
        return os.environ["NVIM_SERVER"]

    # Fallback common socket
    if os.path.exists("/tmp/nvimsocket"):
        return "/tmp/nvimsocket"

    raise RuntimeError("No Neovim server found. Please start Neovim first.")


# ---------------------------------------------------------------------------
# Internal: Lua literal helpers ----------------------------------------------
# ---------------------------------------------------------------------------
def _lua_string_literal(text: str) -> str:
    """Return a Lua double-quoted string literal for *text*.

    Escapes backslashes and double quotes so the result is safe to embed inside
    our lua chunk.
    """
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _lua_table_of_strings(items: Iterable[str]) -> str:
    return "{" + ",".join(_lua_string_literal(s) for s in items) + "}"


def _lua_call(func_name: str, *lua_args: str) -> str:
    """Build the full luaeval() expression string.

    ``func_name`` is the *bare* function name exported by LUA_MODULE.
    Each arg in ``lua_args`` must already be valid Lua syntax (string literal,
    number, table literal, etc.). We do *not* add commas around empty args.
    """
    args = ",".join(lua_args)
    return f"luaeval('require(\"{LUA_MODULE}\").{func_name}({args})')"


def _run_nvr(lua_expr: str) -> str:
    """Run nvr --remote-expr <lua_expr> and return stdout; JSON error on failure."""
    nvim_server = get_nvim_server()

    # Optional debug: set NVIM_LSP_DEBUG=1 to see the command & expr
    if os.environ.get("NVIM_LSP_DEBUG"):
        print(f"[nvim-lsp DEBUG] server={nvim_server} expr={lua_expr}", file=sys.stderr)

    result = subprocess.run(
        ["nvr", "--servername", nvim_server, "--remote-expr", lua_expr],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return json.dumps({"error": result.stderr})
    return result.stdout


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
    # Normalize --------------------------------------------------------------
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

    # Build Lua args ---------------------------------------------------------
    if file_paths:
        lua_arg = _lua_table_of_strings(file_paths)  # type: ignore[arg-type]
        lua_expr = _lua_call("get_diagnostics", lua_arg)
    else:
        lua_expr = _lua_call("get_diagnostics")

    return _run_nvr(lua_expr)


@mcp.tool()
def get_diagnostic_context(file_path: str, line: int) -> str:
    """Get code context around a specific diagnostic."""
    lua_path = _lua_string_literal(file_path)
    lua_line = str(int(line))
    lua_expr = _lua_call("get_diagnostic_context", lua_path, lua_line)
    return _run_nvr(lua_expr)


@mcp.tool()
def get_diagnostic_summary() -> str:
    """Get a summary of all diagnostics across the project."""
    lua_expr = _lua_call("get_diagnostic_summary")
    return _run_nvr(lua_expr)


@mcp.tool()
def get_session_diagnostics() -> str:
    """Get diagnostics only for files edited in the current Claude session."""
    lua_expr = _lua_call("get_session_diagnostics")
    return _run_nvr(lua_expr)


# ---------------------------------------------------------------------------
# Main ----------------------------------------------------------------------
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    mcp.run()


# ---------------------------------------------------------------------------
# NOTE: Future robustness idea ------------------------------------------------
# ---------------------------------------------------------------------------
# If you want *maximal* safety against wild file names (newlines, weird control
# chars), you can JSON-encode the Python-side list and decode in Lua.
# Example (conceptual):
#
#   expr = (
#       "luaeval('require(\"nvim-claude.mcp-bridge\").get_diagnostics(vim.json.decode(_A))',"
#       + json.dumps(file_paths) +
#       ")"
#   )
#
# However, `--remote-expr` only takes *one* expression, so you'd need to embed the
# JSON literal directly in the Lua chunk (not pass it as _A). Something like:
#
#   json_arg = json.dumps(file_paths).replace("'", "\\'")  # careful quoting
#   expr = f"luaeval('require(\"{LUA_MODULE}\").get_diagnostics(vim.json.decode([[{json_arg}]]))')"
#
# Using long-bracket Lua strings ([[..]]) can reduce escaping, but the simple table
# approach used above is usually sufficient and much easier to reason about.
