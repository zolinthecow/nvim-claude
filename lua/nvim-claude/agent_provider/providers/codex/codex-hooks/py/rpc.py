#!/usr/bin/env python3
import os
import subprocess
from pathlib import Path


def run_remote_expr(plugin_root: Path, expr: str, target_path: str | None = None) -> int:
    rpc = plugin_root / 'rpc' / 'nvim-rpc.sh'
    env = os.environ.copy()
    if target_path:
        env['TARGET_FILE'] = target_path
    try:
        cp = subprocess.run([str(rpc), '--remote-expr', expr], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return cp.returncode
    except Exception:
        return 1

