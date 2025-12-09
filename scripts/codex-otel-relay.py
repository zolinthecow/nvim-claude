#!/usr/bin/env python3
"""
Codex OTEL relay: receives OTLP/HTTP logs on 127.0.0.1:<port> and forwards
payloads to the correct Neovim instance based on the git root derived from attrs.
"""

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import pynvim  # type: ignore
except Exception as exc:  # pragma: no cover - best effort import
    sys.stderr.write(f"[relay] pynvim import failed: {exc}\n")
    sys.exit(1)

LOG_LOCK = threading.Lock()


def log(msg):
    with LOG_LOCK:
        print(msg, file=sys.stderr, flush=True)


def decode_any(value):
    if not isinstance(value, dict):
        return value
    for key in ("stringValue", "string_value"):
        if key in value:
            return value[key]
    for key in ("boolValue", "bool_value"):
        if key in value:
            return value[key]
    for key in ("intValue", "int_value"):
        if key in value:
            try:
                return int(value[key])
            except Exception:
                return value[key]
    for key in ("doubleValue", "double_value"):
        if key in value:
            return value[key]
    for key in ("bytesValue", "bytes_value"):
        if key in value:
            return value[key]

    arr = value.get("arrayValue") or value.get("array_value")
    if isinstance(arr, dict) and isinstance(arr.get("values"), list):
        return [decode_any(v) for v in arr["values"]]

    kv = value.get("kvlistValue") or value.get("kvlist_value")
    if isinstance(kv, dict) and isinstance(kv.get("values"), list):
        out = {}
        for entry in kv["values"]:
            if isinstance(entry, dict) and "key" in entry:
                out[entry["key"]] = decode_any(entry.get("value"))
        return out

    return value


def attributes_to_map(attr_list):
    out = {}
    if not isinstance(attr_list, list):
        return out
    for item in attr_list:
        if isinstance(item, dict):
            key = item.get("key") or item.get("name")
            if key:
                out[key] = decode_any(item.get("value"))
    return out


def find_git_root(path_str):
    if not path_str:
        return None
    p = Path(path_str).expanduser().resolve()
    if p.is_file():
        p = p.parent
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(p),
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            root = result.stdout.strip()
            return root if root else None
    except Exception:
        return None
    return None


def project_hash(git_root):
    return hashlib.sha256(git_root.encode()).hexdigest()[:8]


def server_file(git_root):
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return Path(runtime_dir) / f"nvim-claude-{project_hash(git_root)}-server"


def load_project_roots():
    """Return list of project roots from global project-state."""
    state_path = Path.home() / ".local" / "share" / "nvim" / "nvim-claude" / "projects" / "state.json"
    if not state_path.exists():
        return []
    try:
        data = json.loads(state_path.read_text())
    except Exception:
        return []
    return list(data.keys())


def normalize_path(p):
    if not p:
        return None
    p = p.strip()
    if p == "":
        return None
    # drop leading b/ or a/ prefixes, ./, //
    for pref in ("b/", "a/"):
        if p.startswith(pref):
            p = p[len(pref):]
            break
    if p.startswith("./"):
        p = p[2:]
    while p.startswith("//"):
        p = p[1:]
    return p


def extract_paths_from_patch(patch_text):
    paths = set()
    if not isinstance(patch_text, str):
        return paths
    for line in patch_text.splitlines():
        if line.startswith("*** Update File: "):
            paths.add(normalize_path(line.split(":", 1)[1].strip()))
        elif line.startswith("*** Add File: "):
            paths.add(normalize_path(line.split(":", 1)[1].strip()))
        elif line.startswith("*** Delete File: "):
            paths.add(normalize_path(line.split(":", 1)[1].strip()))
        elif line.startswith("*** Move to: "):
            paths.add(normalize_path(line.split(":", 1)[1].strip()))
    paths.discard(None)
    return paths


def best_project_for_path(path, project_roots):
    if not path or not project_roots:
        return None
    # If absolute, pick the longest root that prefixes the path
    if path.startswith("/"):
        best = None
        for root in project_roots:
            if path.startswith(root.rstrip("/") + "/") or path == root:
                if best is None or len(root) > len(best):
                    best = root
        return best
    # Relative: try roots where the file exists
    best = None
    for root in project_roots:
        candidate = Path(root) / path
        if candidate.exists():
            if best is None or len(root) > len(best):
                best = root
    # Fallback: choose longest root (most specific) if nothing exists
    if best is None and project_roots:
        best = max(project_roots, key=len)
    return best


class NeovimRouter:
    def __init__(self):
        self.clients = {}

    def _connect(self, git_root):
        sf = server_file(git_root)
        if not sf.exists():
            return None
        addr = sf.read_text().strip()
        if not addr:
            return None
        try:
            nvim = pynvim.attach("socket", path=addr)
            self.clients[git_root] = nvim
            return nvim
        except Exception as exc:
            log(f"[relay] attach failed for {git_root}: {exc}")
            return None

    def forward(self, git_root, payload):
        nvim = self.clients.get(git_root) or self._connect(git_root)
        if not nvim:
            log(f"[relay] no Neovim instance for {git_root}")
            return
        try:
            nvim.exec_lua(
                'return require("nvim-claude.agent_provider.providers.codex.otel_listener").process_payload(...)',
                payload,
            )
        except Exception as exc:
            log(f"[relay] exec_lua failed for {git_root}: {exc}")
            self.clients.pop(git_root, None)


router = NeovimRouter()


def extract_git_root(resource_attrs, record_attrs):
    merged = dict(resource_attrs)
    merged.update(record_attrs or {})
    for key in ("cwd", "git_root", "project_root", "root"):
        root = merged.get(key)
        if isinstance(root, str):
            git_root = find_git_root(root)
            if git_root:
                return git_root
    file_path = merged.get("file_path") or merged.get("target_file")
    if isinstance(file_path, str):
        git_root = find_git_root(file_path)
        if git_root:
            return git_root
    return None


def split_payload(payload):
    """
    Yield (project_root, single_payload_dict) tuples.
    For codex.tool_result/apply_patch, infer project root from patch paths.
    """
    resource_logs = payload.get("resourceLogs") or payload.get("resource_logs")
    if not isinstance(resource_logs, list):
        return

    project_roots = load_project_roots()

    for resource in resource_logs:
        res_attrs = attributes_to_map(
            resource.get("resource", {}).get("attributes")
        )
        scope_logs = resource.get("scopeLogs") or resource.get("scope_logs") or []
        for scope in scope_logs:
            log_records = scope.get("logRecords") or scope.get("log_records") or []
            for record in log_records:
                rec_attrs = attributes_to_map(record.get("attributes"))
                if record.get("body") is not None:
                    rec_attrs["body"] = decode_any(record.get("body"))

                event_name = rec_attrs.get("event.name") or rec_attrs.get("event_name")
                tool_name = rec_attrs.get("tool_name")

                if event_name != "codex.tool_result" or tool_name != "apply_patch":
                    # Ignore non-apply_patch events
                    continue

                patch_text = rec_attrs.get("arguments") or rec_attrs.get("tool_arguments") or rec_attrs.get("body") or ""
                paths = extract_paths_from_patch(patch_text)
                targets = set()
                for p in paths:
                    root = best_project_for_path(p, project_roots)
                    if root:
                        targets.add(root)

                if not targets:
                    log("[relay] dropped log record (apply_patch without resolvable path)")
                    continue

                for git_root in targets:
                    single_payload = {
                        "resourceLogs": [
                            {
                                "resource": resource.get("resource", {}),
                                "scopeLogs": [
                                    {
                                        "scope": scope.get("scope") or scope.get("instrumentationScope"),
                                        "logRecords": [record],
                                    }
                                ],
                            }
                        ]
                    }
                    yield git_root, single_payload


class RelayHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/logs":
            self.send_response(404)
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except Exception:
            length = 0
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except Exception as exc:
            log(f"[relay] JSON decode failed: {exc}")
            self.send_response(400)
            self.end_headers()
            return

        for git_root, single in split_payload(payload) or []:
            router.forward(git_root, single)
            log(f"[relay] forwarded payload to {git_root}")

        self.send_response(200)
        self.end_headers()

    def log_message(self, *args, **kwargs):
        # Silence default logging
        return


def write_pid(path):
    Path(path).write_text(str(os.getpid()))


def serve_forever(port, pid_path):
    server = ThreadingHTTPServer(("127.0.0.1", port), RelayHandler)
    write_pid(pid_path)
    log(f"[relay] listening on 127.0.0.1:{port}")
    server.serve_forever(poll_interval=0.5)


def main():
    parser = argparse.ArgumentParser(description="Codex OTEL relay")
    parser.add_argument("--port", type=int, default=4318)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--log-file", required=False)
    args = parser.parse_args()

    if args.log_file:
        try:
            sys.stderr = open(args.log_file, "a", buffering=1)
        except Exception:
            pass

    def handle_sigterm(_signum, _frame):
        log("[relay] exiting on SIGTERM")
        try:
            os.remove(args.pid_file)
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    try:
        serve_forever(args.port, args.pid_file)
    finally:
        try:
            os.remove(args.pid_file)
        except Exception:
            pass


if __name__ == "__main__":
    main()
