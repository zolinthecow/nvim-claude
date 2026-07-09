#!/usr/bin/env python3
"""Smoke-test the MCP bridge against its owned headless Neovim."""

import importlib.util
import json
import os


SERVER_PATH = os.path.join(os.path.dirname(__file__), "nvim-lsp-server.py")


def load_server():
    spec = importlib.util.spec_from_file_location("nvim_lsp_server", SERVER_PATH)
    if not spec or not spec.loader:
        raise RuntimeError(f"Could not load module spec from {SERVER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    server = load_server()
    try:
        socket_path = server.ensure_headless_nvim()
        if not server.test_socket_responsive(socket_path):
            raise RuntimeError(f"Headless Neovim is not responsive: {socket_path}")

        diagnostics = json.loads(server.call_headless_lua("get_diagnostics", []))
        if not isinstance(diagnostics, dict) or "error" in diagnostics:
            raise RuntimeError(f"Diagnostics call failed: {diagnostics}")

        summary = json.loads(server.call_headless_lua("get_diagnostic_summary"))
        if not isinstance(summary, dict) or "error" in summary:
            raise RuntimeError(f"Summary call failed: {summary}")
    finally:
        server.cleanup_headless()

    print("MCP bridge smoke test passed")


if __name__ == "__main__":
    main()
