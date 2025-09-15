#!/usr/bin/env python3
import os
import sys
import json
import hashlib
from pathlib import Path


def json_in(argv: list[str]) -> dict:
    if argv and argv[-1].strip().startswith('{'):
        try:
            return json.loads(argv[-1])
        except Exception:
            pass
    try:
        data = sys.stdin.read()
        if data.strip():
            return json.loads(data)
    except Exception:
        pass
    return {}


def get_git_root(cwd: str | None, json_git_root: str | None) -> str:
    if json_git_root and json_git_root != 'null':
        return json_git_root
    cwd = cwd or os.getcwd()
    try:
        import subprocess
        out = subprocess.run(
            ['git', 'rev-parse', '--show-toplevel'],
            cwd=cwd,
            capture_output=True,
            text=True,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return cwd


def _project_key(path: str) -> str:
    return str(Path(path).resolve())


def log_path_for_project(path: str) -> Path:
    root = _project_key(path)
    h = hashlib.sha256(root.encode()).hexdigest()[:8]
    log_dir = Path.home() / '.local/share/nvim/nvim-claude/logs' / h
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir / 'debug.log'


def log(log_file: Path, msg: str) -> None:
    try:
        with open(log_file, 'a') as f:
            from datetime import datetime
            ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            f.write(f'[{ts}] {msg}\n')
    except Exception:
        pass


def plugin_root(start: Path | None = None) -> Path:
    here = start or Path(__file__).resolve().parent
    # Walk up to find rpc/nvim-rpc.sh
    cur = here
    for _ in range(12):
        cand = cur / 'rpc' / 'nvim-rpc.sh'
        if cand.exists():
            return cur
        cur = cur.parent
    # Fallback to known offset relative to hooks dir
    return (here / '..' / '..' / '..' / '..' / '..' / '..').resolve()


def realpath(path: str) -> str:
    try:
        return str(Path(path).resolve())
    except Exception:
        return path

