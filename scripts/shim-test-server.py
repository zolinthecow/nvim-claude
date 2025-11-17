#!/usr/bin/env python3
"""Shim JSON-RPC test harness.

Run this script to capture and validate the JSON payloads emitted by the
filesystem shim. The shim should connect over either a Unix domain socket
or TCP (localhost) and send newline-delimited JSON-RPC requests that
mirror ACP's fs.* methods. The server prints a short summary for each
message and appends the raw JSON to a log file so we can diff/inspect it.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
from pathlib import Path
from typing import Dict, Optional


ALLOWED_METHODS = {
    "fs/write_text_file",
    "fs/remove",
    "fs/rename",
    "fs/read_text_file",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--unix",
        type=Path,
        help="Path to a Unix socket to listen on (default: /tmp/nvim-claude-shim-test.sock)",
    )
    group.add_argument(
        "--port",
        type=int,
        help="TCP port to listen on (localhost only).",
    )
    parser.add_argument(
        "--log",
        type=Path,
        default=Path("shim-test-log.jsonl"),
        help="Where to append received JSON payloads (default: shim-test-log.jsonl)",
    )
    return parser.parse_args()


def validate_request(payload: Dict) -> Optional[str]:
    """Basic sanity checks for shim payloads."""

    if not isinstance(payload, dict):
        return "payload is not a JSON object"

    method = payload.get("method")
    if method not in ALLOWED_METHODS:
        return f"unexpected method: {method!r}"

    params = payload.get("params")
    if not isinstance(params, dict):
        return "params must be an object"

    if method == "fs/write_text_file":
        if "path" not in params or "content" not in params:
            return "write_text_file requires path + content"
    elif method in {"fs/remove", "fs/read_text_file"}:
        if "path" not in params:
            return f"{method} requires path"
    elif method == "fs/rename":
        if "oldPath" not in params or "newPath" not in params:
            return "rename requires oldPath + newPath"

    return None


def log_payload(log_path: Path, payload: Dict) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as fh:
        json.dump(payload, fh)
        fh.write("\n")


def handle_connection(conn: socket.socket, addr: str, log_path: Path) -> None:
    peer = f"{addr}"
    with conn, conn.makefile("r", encoding="utf-8") as reader:
        for raw in reader:
            raw = raw.strip()
            if not raw:
                continue
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError as exc:
                print(
                    f"[shim-test] malformed JSON from {peer}: {exc}: {raw[:120]}...",
                    file=sys.stderr,
                )
                continue

            error = validate_request(payload)
            if error:
                print(
                    f"[shim-test] invalid payload from {peer}: {error}; data={payload}",
                    file=sys.stderr,
                )
                continue

            method = payload.get("method")
            params = payload.get("params", {})
            summary = {
                "fs/write_text_file": lambda: f"write -> {params.get('path')}",
                "fs/remove": lambda: f"remove -> {params.get('path')}",
                "fs/rename": lambda: f"rename {params.get('oldPath')} -> {params.get('newPath')}",
                "fs/read_text_file": lambda: f"read -> {params.get('path')}",
            }[method]()
            print(f"[shim-test] {summary}")
            log_payload(log_path, payload)


def serve_unix(path: Path, log_path: Path) -> None:
    if path.exists():
        path.unlink()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(str(path))
    sock.listen()
    print(f"[shim-test] listening on unix://{path}")

    try:
        while True:
            conn, _ = sock.accept()
            threading.Thread(
                target=handle_connection,
                args=(conn, str(path), log_path),
                daemon=True,
            ).start()
    finally:
        sock.close()
        if path.exists():
            path.unlink()


def serve_tcp(port: int, log_path: Path) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen()
    print(f"[shim-test] listening on tcp://127.0.0.1:{port}")

    with sock:
        while True:
            conn, addr = sock.accept()
            threading.Thread(
                target=handle_connection,
                args=(conn, f"{addr[0]}:{addr[1]}", log_path),
                daemon=True,
            ).start()


def main() -> None:
    args = parse_args()
    if args.unix:
        serve_unix(args.unix, args.log)
    else:
        port = args.port or 43180
        serve_tcp(port, args.log)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("[shim-test] shutting down", file=sys.stderr)
