#!/usr/bin/env python3
"""
Neovim RPC client to replace nvr (neovim-remote).
This script connects to a running Neovim instance and executes commands.
"""

import sys
import os
import hashlib
import tempfile
from pathlib import Path
import pynvim
import json


def find_project_root(start_path=None):
    """Find the project root by looking for .git directory."""
    if start_path:
        current = Path(start_path).resolve()
    else:
        current = Path.cwd()
    
    while current != current.parent:
        if (current / '.git').exists():
            return str(current)
        current = current.parent
    return None


def get_server_address(project_root):
    """Get the Neovim server address for the given project."""
    # Generate the same hash as Neovim to find the server file
    project_hash = hashlib.sha256(project_root.encode()).hexdigest()[:8]
    
    # Check XDG_RUNTIME_DIR first, then /tmp
    runtime_dir = os.environ.get('XDG_RUNTIME_DIR', '/tmp')
    server_file = Path(runtime_dir) / f'nvim-claude-{project_hash}-server'
    
    if server_file.exists():
        server_address = server_file.read_text().strip()
        if server_address and Path(server_address).exists():
            return server_address
    
    # Fallback: Find any Neovim server in temp directories
    for temp_dir in ['/var/folders', '/tmp']:
        temp_path = Path(temp_dir)
        if temp_path.exists():
            for socket in temp_path.glob('**/nvim.*.0'):
                if socket.is_socket():
                    return str(socket)
    
    return None


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print('Usage: nvim_rpc.py [--remote-expr EXPR | --remote-send KEYS | -c CMD]', file=sys.stderr)
        sys.exit(1)
    
    # Get the target file from environment if provided
    target_file = os.environ.get('TARGET_FILE')
    if target_file:
        file_dir = Path(target_file).parent
        # Try to get project root from target file's directory
        try:
            import subprocess
            result = subprocess.run(
                ['git', 'rev-parse', '--show-toplevel'],
                cwd=file_dir,
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                project_root = result.stdout.strip()
            else:
                project_root = find_project_root(file_dir)
        except:
            project_root = find_project_root(file_dir)
    else:
        project_root = find_project_root()
    
    if not project_root:
        print('Error: Not in a git repository', file=sys.stderr)
        sys.exit(1)
    
    # Find the server address
    server_address = get_server_address(project_root)
    if not server_address:
        print('Error: No Neovim server found', file=sys.stderr)
        sys.exit(1)
    
    try:
        # Connect to Neovim
        nvim = pynvim.attach('socket', path=server_address)
        
        # Parse and execute the command
        if sys.argv[1] == '--remote-expr' and len(sys.argv) > 2:
            # Evaluate expression
            expr = sys.argv[2]
            result = nvim.eval(expr)
            
            # Handle different result types
            if result is None:
                pass  # Don't print anything for None
            elif isinstance(result, (dict, list)):
                # For complex types, use JSON
                print(json.dumps(result))
            else:
                # For simple types, print directly
                print(result)
                
        elif sys.argv[1] == '--remote-send' and len(sys.argv) > 2:
            # Send keys
            keys = sys.argv[2]
            nvim.input(keys)
            
        elif sys.argv[1] == '-c' and len(sys.argv) > 2:
            # Execute command
            cmd = sys.argv[2]
            nvim.command(cmd)
            
        else:
            print(f'Unknown command: {sys.argv[1]}', file=sys.stderr)
            sys.exit(1)
            
    except pynvim.api.nvim.NvimError as e:
        print(f'Nvim error: {e}', file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f'Error: {e}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()