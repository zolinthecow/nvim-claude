#!/usr/bin/env python3
"""
Get diagnostics from headless Neovim for stop hook
"""
import sys
import json
import os
import subprocess
import tempfile
import hashlib
import time

def get_project_hash():
    """Get project hash for socket name"""
    cwd = os.getcwd()
    return hashlib.md5(cwd.encode()).hexdigest()[:8]

def call_headless_lua(file_paths):
    """Call the MCP bridge in headless Neovim"""
    project_hash = get_project_hash()
    socket_path = f"/tmp/nvim-claude-headless-{project_hash}.sock"
    
    # Check if headless instance exists, if not start one
    if not os.path.exists(socket_path):
        # Start headless Neovim (same as MCP server does)
        nvim_cmd = ["nvim", "--headless", "--listen", socket_path]
        
        # Create init file for headless instance
        init_content = f"""
-- Headless init for stop hook diagnostics
vim.g.headless_mode = true

-- Load user config if it exists
local user_init = vim.fn.expand('~/.config/nvim/init.lua')
if vim.fn.filereadable(user_init) == 1 then
  dofile(user_init)
end

-- Ensure diagnostics are enabled
vim.diagnostic.config({{
  virtual_text = true,
  signs = true,
  underline = true,
  update_in_insert = false,
  severity_sort = false,
}})
"""
        init_file = f"/tmp/nvim-claude-headless-{project_hash}-init.lua"
        with open(init_file, 'w') as f:
            f.write(init_content)
        
        nvim_cmd.extend(["-u", init_file])
        
        # Start the process
        subprocess.Popen(
            nvim_cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        
        # Wait for socket
        for _ in range(20):
            if os.path.exists(socket_path):
                break
            time.sleep(0.1)
    
    # Now call the diagnostics function
    lua_code = f"""
local mcp_bridge = require('nvim-claude.lsp_mcp.bridge')
local result = mcp_bridge.get_diagnostics({json.dumps(file_paths)})
return result
"""
    
    # Use pynvim to call the function
    import pynvim
    nvim = pynvim.attach('socket', path=socket_path)
    
    try:
        result = nvim.exec_lua(lua_code)
        nvim.close()
        return result
    except Exception as e:
        nvim.close()
        return json.dumps({})

if __name__ == "__main__":
    # Read file paths
    if len(sys.argv) > 1:
        file_paths = sys.argv[1:]
    else:
        # Read from stdin
        input_data = sys.stdin.read()
        try:
            file_paths = json.loads(input_data) if input_data else []
        except:
            file_paths = []
    
    # Get diagnostics
    result_json = call_headless_lua(file_paths)
    
    # Parse and count
    try:
        diagnostics = json.loads(result_json)
        error_count = 0
        warning_count = 0
        
        for file_diags in diagnostics.values():
            for diag in file_diags:
                if diag['severity'] == 'ERROR':
                    error_count += 1
                elif diag['severity'] == 'WARN':
                    warning_count += 1
        
        print(json.dumps({
            "errors": error_count,
            "warnings": warning_count
        }))
    except Exception as e:
        print(json.dumps({"errors": 0, "warnings": 0}))
