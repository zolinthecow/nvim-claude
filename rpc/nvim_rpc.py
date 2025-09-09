#!/usr/bin/env python3
"""
Neovim RPC client to replace nvr (neovim-remote).
This script connects to a running Neovim instance and executes commands.
"""

import sys
import os
import hashlib
from pathlib import Path
import pynvim
import json


def find_project_root(start_path=None):
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
    project_hash = hashlib.sha256(project_root.encode()).hexdigest()[:8]
    runtime_dir = os.environ.get('XDG_RUNTIME_DIR', '/tmp')
    server_file = Path(runtime_dir) / f'nvim-claude-{project_hash}-server'
    if server_file.exists():
        server_address = server_file.read_text().strip()
        if server_address and Path(server_address).exists():
            return server_address
    for temp_dir in ['/var/folders', '/tmp']:
        temp_path = Path(temp_dir)
        if temp_path.exists():
            for socket in temp_path.glob('**/nvim.*.0'):
                if socket.is_socket():
                    return str(socket)
    return None


def main():
    if len(sys.argv) < 2:
        print('Usage: nvim_rpc.py [--remote-expr EXPR | --remote-send KEYS | -c CMD]', file=sys.stderr)
        sys.exit(1)

    target_file = os.environ.get('TARGET_FILE')
    if target_file:
        p = Path(target_file).resolve()
        # If TARGET_FILE is a directory, use it directly; otherwise use its parent
        work_dir = p if p.is_dir() else p.parent
        try:
            import subprocess
            result = subprocess.run(
                ['git', 'rev-parse', '--show-toplevel'],
                cwd=work_dir,
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                project_root = result.stdout.strip()
            else:
                project_root = find_project_root(work_dir)
        except Exception:
            project_root = find_project_root(work_dir)
    else:
        project_root = find_project_root()

    if not project_root:
        print('Error: Not in a git repository', file=sys.stderr)
        sys.exit(1)

    server_address = get_server_address(project_root)
    if not server_address:
        print('Error: No Neovim server found', file=sys.stderr)
        sys.exit(1)

    try:
        nvim = pynvim.attach('socket', path=server_address)

        if sys.argv[1] == '--remote-expr' and len(sys.argv) > 2:
            expr = sys.argv[2]
            result = nvim.eval(expr)
            if result is None:
                pass
            elif isinstance(result, (dict, list)):
                print(json.dumps(result))
            else:
                print(result)
        elif sys.argv[1] == '--remote-send' and len(sys.argv) > 2:
            keys = sys.argv[2]
            nvim.input(keys)
        elif sys.argv[1] == '-c' and len(sys.argv) > 2:
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
