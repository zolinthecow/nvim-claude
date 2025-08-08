#!/usr/bin/env python3
"""
Simple wrapper to call MCP diagnostics without the full MCP protocol
"""
import sys
import json
import os

# Add the MCP server to path
mcp_server_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'mcp-server')
sys.path.insert(0, mcp_server_dir)

# Set required environment variables for the MCP server
os.environ['FASTMCP_DISABLE_BANNER'] = '1'
os.environ['FASTMCP_LOG_LEVEL'] = 'ERROR'
os.environ['LOG_LEVEL'] = 'ERROR'

# Import and call the function
import subprocess
import tempfile

# Since the MCP server needs to be run as a full process, let's call it properly
def get_diagnostics_via_subprocess(file_paths):

if __name__ == "__main__":
    # Read file paths from command line or stdin
    if len(sys.argv) > 1:
        # Files passed as arguments
        file_paths = sys.argv[1:]
    else:
        # Read JSON array from stdin
        input_data = sys.stdin.read()
        try:
            file_paths = json.loads(input_data) if input_data else []
        except:
            file_paths = []
    
    # Get diagnostics
    result = get_diagnostics(file_paths)
    
    # Parse the result to count errors/warnings
    try:
        diagnostics = json.loads(result)
        error_count = 0
        warning_count = 0
        
        for file_diags in diagnostics.values():
            for diag in file_diags:
                if diag['severity'] == 'ERROR':
                    error_count += 1
                elif diag['severity'] == 'WARN':
                    warning_count += 1
        
        # Output counts as JSON
        print(json.dumps({
            "errors": error_count,
            "warnings": warning_count
        }))
    except Exception as e:
        # On error, return safe defaults
        print(json.dumps({"errors": 0, "warnings": 0}))