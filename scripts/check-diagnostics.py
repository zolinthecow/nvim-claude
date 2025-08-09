#!/usr/bin/env python3
"""
Check diagnostics for session files using MCP server
Called from stop-hook-validator.sh
"""
import asyncio
import json
import sys
import os

# Suppress FastMCP banner
os.environ['FASTMCP_DISABLE_BANNER'] = '1'
os.environ['FASTMCP_LOG_LEVEL'] = 'ERROR'
os.environ['LOG_LEVEL'] = 'ERROR'

from fastmcp import Client

# Get script directory to find MCP server
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SERVER_SCRIPT = os.path.join(SCRIPT_DIR, "..", "mcp-server", "nvim-lsp-server.py")

async def check_diagnostics(file_paths):
    """Get diagnostics for files and return error/warning counts"""
    try:
        async with Client(SERVER_SCRIPT) as c:
            # Call get_diagnostics tool
            result = await c.call_tool(
                "get_diagnostics",
                {"file_paths": file_paths}
            )
            
            # Parse the result
            diagnostics = result.data if hasattr(result, "data") else result
            if isinstance(diagnostics, str):
                diagnostics = json.loads(diagnostics)
            
            # Count errors and warnings
            error_count = 0
            warning_count = 0
            
            for file_diags in diagnostics.values():
                for diag in file_diags:
                    if diag.get('severity') == 'ERROR':
                        error_count += 1
                    elif diag.get('severity') == 'WARN':
                        warning_count += 1
            
            return {"errors": error_count, "warnings": warning_count}
            
    except Exception as e:
        # On error, return safe defaults
        print(f"Error: {e}", file=sys.stderr)
        return {"errors": 0, "warnings": 0}

if __name__ == "__main__":
    # Read file paths from command line or stdin
    if len(sys.argv) > 1:
        # Files passed as arguments
        file_paths = sys.argv[1:]
    else:
        # Read JSON array from stdin
        try:
            input_data = sys.stdin.read()
            file_paths = json.loads(input_data) if input_data else []
        except:
            file_paths = []
    
    # Run async function
    counts = asyncio.run(check_diagnostics(file_paths))
    
    # Output as JSON
    print(json.dumps(counts))