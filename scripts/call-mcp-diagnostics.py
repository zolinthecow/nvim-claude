#!/usr/bin/env python3
"""Helper script to call MCP diagnostics directly"""
import sys
import os
import json

# Add the mcp-server directory to Python path
script_dir = os.path.dirname(os.path.abspath(__file__))
mcp_server_dir = os.path.join(os.path.dirname(script_dir), 'mcp-server')
sys.path.insert(0, mcp_server_dir)

import importlib.util
spec = importlib.util.spec_from_file_location("nvim_lsp_server", os.path.join(mcp_server_dir, "nvim-lsp-server.py"))
if spec and spec.loader:
    nvim_lsp_server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nvim_lsp_server)
    get_diagnostics = nvim_lsp_server.get_diagnostics
else:
    raise ImportError("Failed to load nvim-lsp-server module")

if __name__ == "__main__":
    file_path = sys.argv[1] if len(sys.argv) > 1 else None
    result = get_diagnostics([file_path] if file_path else [])
    
    # Parse and pretty print result
    try:
        parsed = json.loads(result)
        print(json.dumps(parsed, indent=2))
    except:
        print(result)