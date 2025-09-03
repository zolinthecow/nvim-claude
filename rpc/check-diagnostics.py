#!/usr/bin/env python3
"""
Check diagnostics for session files using MCP server
Called from stop-hook-validator.sh
"""
import asyncio
import json
import sys
import os

from fastmcp import Client  # type: ignore


async def check_diagnostics(file_paths):
    try:
        # Locate the mcp server script relative to this file
        script_dir = os.path.dirname(os.path.abspath(__file__))
        server_script = os.path.join(script_dir, '..', 'mcp-server', 'nvim-lsp-server.py')
        async with Client(server_script) as c:
            result = await c.call_tool(
                "get_diagnostics",
                {"file_paths": file_paths}
            )
            diagnostics = result.data if hasattr(result, "data") else result
            if isinstance(diagnostics, str):
                diagnostics = json.loads(diagnostics)
            error_count = 0
            warning_count = 0
            for file_diags in diagnostics.values():
                for diag in file_diags:
                    if diag.get('severity') == 'ERROR':
                        error_count += 1
                    elif diag.get('severity') == 'WARN':
                        warning_count += 1
            return {"errors": error_count, "warnings": warning_count}
    except Exception:
        return {"errors": 0, "warnings": 0}


if __name__ == "__main__":
    file_paths = sys.argv[1:]
    counts = asyncio.run(check_diagnostics(file_paths))
    print(json.dumps(counts))

