#!/usr/bin/env python3
"""Test MCP server tools directly"""
import os
import sys
import json

# Add current directory to path to import the server
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Set debug mode
os.environ['NVIM_LSP_DEBUG'] = '1'

try:
    # Import the server module - need to handle the hyphenated filename
    import importlib.util
    server_path = os.path.join(os.path.dirname(__file__), "nvim-lsp-server.py")
    spec = importlib.util.spec_from_file_location("nvim_lsp_server", server_path)
    if spec and spec.loader:
        nvim_lsp_server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(nvim_lsp_server)
    else:
        raise ImportError(f"Could not load module spec from {server_path}")
    
    print("=== Testing MCP Server Tools ===\n")
    
    # Test 1: Check nvim server detection
    print("1. Testing get_nvim_server():")
    try:
        server = nvim_lsp_server.get_nvim_server()
        print(f"   ✓ Found server: {server}")
    except Exception as e:
        print(f"   ✗ Error: {e}")
    print()
    
    # Test 2: Try to get diagnostics
    print("2. Testing get_diagnostics():")
    try:
        result = nvim_lsp_server.get_diagnostics()
        data = json.loads(result)
        if isinstance(data, dict) and 'error' in data:
            print(f"   ✗ Error: {data['error']}")
        else:
            print(f"   ✓ Success! Found diagnostics for {len(data)} files")
            for file in list(data.keys())[:3]:  # Show first 3 files
                print(f"     - {file}")
    except Exception as e:
        print(f"   ✗ Exception: {e}")
    print()
    
    # Test 3: Try to get summary
    print("3. Testing get_diagnostic_summary():")
    try:
        result = nvim_lsp_server.get_diagnostic_summary()
        data = json.loads(result)
        if isinstance(data, dict) and 'error' in data:
            print(f"   ✗ Error: {data['error']}")
        else:
            print(f"   ✓ Success! Total errors: {data.get('total_errors', 0)}, warnings: {data.get('total_warnings', 0)}")
    except Exception as e:
        print(f"   ✗ Exception: {e}")
    
except ImportError as e:
    print(f"Failed to import nvim_lsp_server: {e}")
    print("\nMake sure you have installed the MCP dependencies:")
    print("  Run :ClaudeInstallMCP in Neovim")