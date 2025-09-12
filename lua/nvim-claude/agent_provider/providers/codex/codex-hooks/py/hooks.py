#!/usr/bin/env python3
import os
import sys
import json
import base64
import shlex
import glob
from pathlib import Path

try:
    from .common import json_in, get_git_root, log_path_for_project, log, plugin_root, realpath
    from .patch_parser import extract_patch, iter_targets
    from .rpc import run_remote_expr
except Exception:
    from common import json_in, get_git_root, log_path_for_project, log, plugin_root, realpath  # type: ignore
    from patch_parser import extract_patch, iter_targets  # type: ignore
    from rpc import run_remote_expr  # type: ignore


def b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()


def command_from_json(j: dict) -> str:
    cmd = ''
    # tool_input.command can be a string or array
    ti = j.get('tool_input', {}) if isinstance(j.get('tool_input'), dict) else {}
    if isinstance(ti.get('command'), str):
        cmd = ti['command']
    elif isinstance(ti.get('command'), list):
        cmd = ' '.join(map(str, ti['command']))
    if not cmd:
        args_cmd = j.get('arguments', {}).get('command') if isinstance(j.get('arguments'), dict) else None
        if isinstance(args_cmd, list):
            cmd = ' '.join(map(str, args_cmd))
        elif isinstance(args_cmd, str):
            cmd = args_cmd
    if not cmd and isinstance(j.get('arguments'), dict):
        raw = j['arguments'].get('raw')
        if isinstance(raw, str):
            cmd = raw
    if not cmd and isinstance(j.get('arguments'), dict):
        argv = j['arguments'].get('argv')
        if isinstance(argv, list):
            cmd = ' '.join(map(str, argv))
    return cmd.strip()


def shell_pre(argv: list[str]) -> int:
    j = json_in(argv)
    cwd = j.get('cwd') or os.getcwd()
    git_root = get_git_root(cwd, j.get('git_root'))
    lp = log_path_for_project(git_root)
    log(lp, '[codex shell-pre] called')

    sub_id = j.get('sub_id') or ''
    call_id = j.get('call_id') or ''
    # Touch per-call sentinel
    if call_id:
        tmp_base = Path(os.environ.get('TMPDIR', '/tmp')) / 'nvim-claude-codex-hooks'
        (tmp_base / 'calls').mkdir(parents=True, exist_ok=True)
        ts_file = tmp_base / 'calls' / f"{sub_id or 0}-{call_id}.ts"
        ts_file.write_text('')
        log(lp, f"[codex shell-pre] touch {ts_file}")

    cmd = command_from_json(j)
    log(lp, f"[codex shell-pre] tool={j.get('tool','')} argtype={type(j.get('arguments')).__name__} argkeys={','.join((j.get('arguments') or {}).keys()) if isinstance(j.get('arguments'), dict) else ''} cmd={cmd[:200]}")

    # Track deletes: prefer payload targets
    targets = []
    if isinstance(j.get('targets'), list) and j['targets']:
        for x in j['targets']:
            if isinstance(x, str) and x:
                targets.append(realpath(x))
        for abs_path in targets:
            pr = plugin_root()
            run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').track_deleted_file_b64('{b64(abs_path)}')\")", abs_path)
        log(lp, f"[codex shell-pre] rm targets tracked (payload): {len(targets)}")
    elif cmd.startswith('rm '):
        try:
            toks = shlex.split(cmd)
        except Exception:
            toks = cmd.split()
        paths = [t for t in toks[1:] if not t.startswith('-')]
        expanded = []
        for p in paths:
            # glob expansion relative to cwd
            g = glob.glob(os.path.join(cwd, p)) or [os.path.join(cwd, p)]
            for x in g:
                expanded.append(realpath(x))
        cnt = 0
        for abs_path in expanded:
            if Path(abs_path).exists():
                pr = plugin_root()
                run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').track_deleted_file_b64('{b64(abs_path)}')\")", abs_path)
                cnt += 1
        log(lp, f"[codex shell-pre] rm targets tracked: {cnt}")

    # Parse apply_patch to pre-touch baseline and persist list
    patch = extract_patch(cmd)
    if patch:
        tmp_base = Path(os.environ.get('TMPDIR', '/tmp')) / 'nvim-claude-codex-hooks'
        (tmp_base / 'calls').mkdir(parents=True, exist_ok=True)
        call_file = tmp_base / 'calls' / f"{sub_id or 0}-{call_id}.files"
        seen = set()
        count = 0
        for rel in iter_targets(patch):
            abs_path = realpath(os.path.join(git_root, rel))
            if abs_path in seen:
                continue
            seen.add(abs_path)
            with open(call_file, 'a') as cf:
                cf.write(abs_path + '\n')
            pr = plugin_root()
            run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').pre_tool_use_b64('{b64(abs_path)}')\")", abs_path)
            log(lp, f"[codex shell-pre] apply_patch target: {abs_path}")
            count += 1
        log(lp, f"[codex shell-pre] apply_patch targets pre-touched: {count} (saved: {call_file})")

    log(lp, '[codex shell-pre] done')
    return 0


def shell_post(argv: list[str]) -> int:
    j = json_in(argv)
    cwd = j.get('cwd') or os.getcwd()
    git_root = get_git_root(cwd, j.get('git_root'))
    lp = log_path_for_project(git_root)
    log(lp, '[codex shell-post] called')

    sub_id = j.get('sub_id') or ''
    call_id = j.get('call_id') or ''
    cmd = command_from_json(j)

    success = j.get('success')
    output = j.get('output') or ''
    head = (output or '')[:120]
    argtype = type(j.get('arguments')).__name__
    argkeys = ','.join((j.get('arguments') or {}).keys()) if isinstance(j.get('arguments'), dict) else ''
    log(lp, f"[codex shell-post] tool={j.get('tool','')} argtype={argtype} argkeys={argkeys} cmd={cmd[:200]} success={success} out={head}")

    # Handle rm failures
    deleted = []
    if isinstance(j.get('deleted'), list) and j['deleted']:
        deleted = j['deleted']
        log(lp, f"[codex shell-post] payload deleted count: {len(deleted)}")
    elif cmd.startswith('rm '):
        try:
            toks = shlex.split(cmd)
        except Exception:
            toks = cmd.split()
        paths = [t for t in toks[1:] if not t.startswith('-')]
        expanded = []
        for p in paths:
            g = glob.glob(os.path.join(cwd, p)) or [os.path.join(cwd, p)]
            for x in g:
                expanded.append(realpath(x))
        cnt = 0
        for abs_path in expanded:
            if Path(abs_path).exists():
                pr = plugin_root()
                run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').untrack_failed_deletion_b64('{b64(abs_path)}')\")", abs_path)
                log(lp, f"[codex shell-post] untrack failed delete: {abs_path}")
                cnt += 1
        log(lp, f"[codex shell-post] rm still-present files: {cnt}")

    # Mark edits for apply_patch or fallback to saved list
    if not deleted and not cmd.startswith('rm '):
        pr = plugin_root()
        patch = extract_patch(cmd)
        if patch:
            n = 0
            for rel in iter_targets(patch):
                abs_path = realpath(os.path.join(git_root, rel))
                run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('{b64(abs_path)}')\")", git_root)
                log(lp, f"[codex shell-post] marking edited (apply_patch cmd): {abs_path}")
                n += 1
            log(lp, f"[codex shell-post] apply_patch edited count: {n}")
        else:
            tmp_base = Path(os.environ.get('TMPDIR', '/tmp')) / 'nvim-claude-codex-hooks'
            call_file = tmp_base / 'calls' / f"{sub_id or 0}-{call_id}.files"
            if call_file.exists():
                n = 0
                for line in call_file.read_text().splitlines():
                    abs_path = line.strip()
                    if not abs_path:
                        continue
                    run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').post_tool_use_b64('{b64(abs_path)}')\")", git_root)
                    log(lp, f"[codex shell-post] marking edited (call-file): {abs_path}")
                    n += 1
                try:
                    call_file.unlink()
                except Exception:
                    pass
                log(lp, f"[codex shell-post] call-file edited count: {n}")
            else:
                log(lp, '[codex shell-post] non-edit shell command; not marking edits')

    log(lp, '[codex shell-post] done')
    return 0


def stop(argv: list[str]) -> int:
    j = json_in(argv)
    cwd = j.get('cwd') or os.getcwd()
    git_root = get_git_root(cwd, j.get('git_root'))
    lp = log_path_for_project(git_root)
    log(lp, f"[codex stop] called sub={j.get('sub_id','')} call={j.get('call_id','')} cwd={cwd} git_root={git_root}")

    # Load session files from project state
    state_file = Path.home() / '.local/share/nvim/nvim-claude/projects/state.json'
    files = []
    if state_file.exists():
        try:
            state = json.loads(state_file.read_text() or '{}')
            files = state.get(str(Path(git_root).resolve()), {}).get('session_edited_files', [])
        except Exception:
            files = []
    if not files:
        log(lp, '[codex stop] no session files; approving')
        print('{"decision": "approve"}')
        return 0

    # One-shot MCP diagnostics for all files
    pr = plugin_root()
    import subprocess, time
    start = time.time()
    try:
        out = subprocess.run([str(Path.home() / '.local/share/nvim/nvim-claude/mcp-env/bin/python'), str(pr / 'rpc' / 'check-diagnostics.py'), *files], capture_output=True, text=True)
        result_json = out.stdout.strip() or '{}'
    except Exception:
        result_json = '{}'
    try:
        counts = json.loads(result_json)
    except Exception:
        counts = {"errors": 0, "warnings": 0}
    elapsed = int(time.time() - start)
    log(lp, f"[codex stop] diagnostics done errors={counts.get('errors',0)} warnings={counts.get('warnings',0)} elapsed={elapsed}s")

    if counts.get('errors', 0) > 0:
        try:
            sess = subprocess.run([str(Path.home() / '.local/share/nvim/nvim-claude/mcp-env/bin/python'), str(pr / 'rpc' / 'get-session-diagnostics.py')], capture_output=True, text=True)
            reason = json.dumps(sess.stdout)
        except Exception:
            reason = json.dumps('diagnostics failed')
        print(f'{{"decision":"block","reason":{reason}}}')
    else:
        # Clear session files via RPC
        run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').clear_turn_files_for_path_b64('{b64(str(Path(git_root).resolve()))}')\")", git_root)
        print('{"decision": "approve"}')
    return 0


def user_prompt(argv: list[str]) -> int:
    j = json_in(argv)
    cwd = j.get('cwd') or os.getcwd()
    git_root = get_git_root(cwd, j.get('git_root'))
    lp = log_path_for_project(git_root)
    log(lp, '[codex user-prompt-submit] called')
    sub_id = j.get('sub_id') or ''
    call_id = j.get('call_id') or ''
    log(lp, f"[codex user-prompt-submit] ids sub={sub_id} call={call_id}")
    log(lp, f"[codex user-prompt-submit] paths cwd={cwd} git_root={git_root}")
    # Concatenate texts array items with blank lines
    prompt = ''
    texts = j.get('texts') or []
    if isinstance(texts, list):
        prompt = '\n\n'.join([t for t in texts if isinstance(t, str)])
    log(lp, f"[codex user-prompt-submit] prompt head: {prompt[:120]}")
    pr = plugin_root()
    run_remote_expr(pr, f"luaeval(\"require('nvim-claude.events.adapter').user_prompt_submit_b64('{b64(prompt)}')\")", git_root)
    log(lp, '[codex user-prompt-submit] done')
    return 0


def main():
    if len(sys.argv) < 2:
        print('usage: hooks.py <shell-pre|shell-post|stop|user-prompt> [JSON]', file=sys.stderr)
        return 1
    cmd = sys.argv[1]
    rest = sys.argv[2:]
    if cmd == 'shell-pre':
        return shell_pre(rest)
    if cmd == 'shell-post':
        return shell_post(rest)
    if cmd == 'stop':
        return stop(rest)
    if cmd in ('user-prompt', 'user_prompt'):
        return user_prompt(rest)
    print(f'unknown subcommand: {cmd}', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
