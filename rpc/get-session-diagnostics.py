#!/usr/bin/env python3
"""
Print full session diagnostics JSON via FastMCP client.
Used by the Stop hook to embed detailed diagnostics in the reason field.
"""
import asyncio
import json
import os
import sys

from fastmcp import Client  # type: ignore


async def get_session():
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        server_script = os.path.join(script_dir, '..', 'mcp-server', 'nvim-lsp-server.py')
        async with Client(server_script) as c:
            r = await c.call_tool('get_session_diagnostics')
            data = getattr(r, 'data', r)
            if isinstance(data, str):
                print(data)
            else:
                print(json.dumps(data))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == '__main__':
    asyncio.run(get_session())

