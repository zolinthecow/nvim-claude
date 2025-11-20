#!/usr/bin/env python3
import argparse
import itertools
import json
import os
import socket
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Minimal JSON-RPC sidecar for the fs shim.'
    )
    parser.add_argument(
        '--sock',
        default=os.environ.get('NVIM_CLAUDE_SHIM_SOCK', '/tmp/fs_shim.sock'),
        help='Unix socket path to listen on (default: %(default)s).',
    )
    parser.add_argument(
        '--log',
        default=None,
        help='Optional JSONL log file for all shim events.',
    )
    parser.add_argument(
        '--deny-method',
        action='append',
        default=[],
        metavar='METHOD',
        help='Respond with allow=false for matching pre_* method(s) (repeatable).',
    )
    parser.add_argument(
        '--no-stdout',
        action='store_true',
        help='Silence stdout (logs still go to file if provided).',
    )
    parser.add_argument(
        '--backlog',
        type=int,
        default=64,
        help='listen backlog (default: %(default)s)',
    )
    return parser.parse_args()


class Logger:
    def __init__(self, log_path: Optional[str], quiet: bool) -> None:
        self.quiet = quiet
        self._lock = threading.Lock()
        self._fh = None
        if log_path:
            path = Path(log_path).expanduser()
            path.parent.mkdir(parents=True, exist_ok=True)
            self._fh = path.open('a', buffering=1)

    def write(self, record: dict) -> None:
        record.setdefault('ts', datetime.now(timezone.utc).isoformat())
        line = json.dumps(record, sort_keys=True)
        with self._lock:
            if not self.quiet:
                print(line, flush=True)
            if self._fh:
                self._fh.write(line + '\n')

    def close(self) -> None:
        if self._fh:
            self._fh.close()


def handle_connection(conn: socket.socket, conn_id: int, deny: set[str], logger: Logger) -> None:
    with conn:
        f = conn.makefile('rwb', buffering=0)
        while True:
            line = f.readline()
            if not line:
                logger.write({'conn': conn_id, 'kind': 'disconnect'})
                return
            try:
                message = json.loads(line)
            except json.JSONDecodeError as exc:
                logger.write(
                    {
                        'conn': conn_id,
                        'kind': 'error',
                        'error': f'bad json: {exc}',
                        'raw': line.decode('utf-8', errors='replace').strip(),
                    }
                )
                continue

            method = message.get('method', '')
            logger.write({'conn': conn_id, 'kind': 'recv', 'message': message})

            if message.get('id') is None:
                continue

            allow = method not in deny
            reply = {'jsonrpc': '2.0', 'id': message['id'], 'result': {'allow': bool(allow)}}
            f.write((json.dumps(reply) + '\n').encode('utf-8'))
            f.flush()
            logger.write({'conn': conn_id, 'kind': 'ack', 'method': method, 'allow': allow})


def main() -> None:
    args = parse_args()
    sock_path = Path(args.sock).expanduser()
    if sock_path.exists():
        sock_path.unlink()

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    server.listen(args.backlog)

    logger = Logger(args.log, quiet=args.no_stdout)
    logger.write({'kind': 'listening', 'sock': str(sock_path)})

    deny_set = set(args.deny_method)
    counter = itertools.count(1)

    shutdown = threading.Event()

    def accept_loop() -> None:
        while not shutdown.is_set():
            try:
                conn, _ = server.accept()
            except OSError:
                break
            conn_id = next(counter)
            logger.write({'conn': conn_id, 'kind': 'accept'})
            thread = threading.Thread(
                target=handle_connection,
                args=(conn, conn_id, deny_set, logger),
                daemon=True,
            )
            thread.start()

    try:
        accept_loop()
    except KeyboardInterrupt:
        logger.write({'kind': 'shutdown', 'reason': 'keyboard_interrupt'})
    finally:
        shutdown.set()
        server.close()
        try:
            sock_path.unlink()
        except FileNotFoundError:
            pass
        logger.close()


if __name__ == '__main__':
    main()
