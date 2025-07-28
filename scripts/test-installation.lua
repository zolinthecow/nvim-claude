#!/usr/bin/env nvim -l
-- Test script to verify nvim-claude installation
-- Run with: nvim -l path/to/test-installation.lua

print('=== nvim-claude Installation Test ===\n')

-- Test 1: Can we load the plugin?
print('1. Loading plugin...')
local ok, plugin = pcall(require, 'nvim-claude')
if ok then
  print('   ✓ Plugin loaded successfully')
else
  print('   ✗ Failed to load plugin: ' .. tostring(plugin))
  os.exit(1)
end

-- Test 2: Check plugin directory
print('\n2. Checking plugin directory...')
if plugin.get_plugin_dir then
  local dir = plugin.get_plugin_dir()
  if dir then
    print('   ✓ Plugin directory found: ' .. dir)
    
    -- Check for important subdirectories
    local subdirs = {'lua/nvim-claude', 'mcp-server', 'scripts'}
    for _, subdir in ipairs(subdirs) do
      local exists = vim.fn.isdirectory(dir .. subdir) == 1
      if exists then
        print('   ✓ ' .. subdir .. ' exists')
      else
        print('   ✗ ' .. subdir .. ' missing')
      end
    end
  else
    print('   ✗ Could not find plugin directory')
  end
else
  print('   ✗ get_plugin_dir function not available')
end

-- Test 3: Check dependencies
print('\n3. Checking dependencies...')
local deps = {
  { name = 'plenary', module = 'plenary' },
  { name = 'neovim-remote (nvr)', command = 'nvr' },
  { name = 'tmux', command = 'tmux' },
  { name = 'git', command = 'git' },
}

for _, dep in ipairs(deps) do
  if dep.module then
    local ok = pcall(require, dep.module)
    if ok then
      print('   ✓ ' .. dep.name .. ' (lua module) found')
    else
      print('   ✗ ' .. dep.name .. ' (lua module) not found')
    end
  elseif dep.command then
    local exists = vim.fn.executable(dep.command) == 1
    if exists then
      print('   ✓ ' .. dep.name .. ' command found')
    else
      print('   ✗ ' .. dep.name .. ' command not found')
    end
  end
end

-- Test 4: Check MCP installation
print('\n4. Checking MCP server...')
local venv_path = vim.fn.expand('~/.local/share/nvim/nvim-claude/mcp-env')
local venv_exists = vim.fn.isdirectory(venv_path) == 1
if venv_exists then
  print('   ✓ MCP virtual environment exists')
  local python_exists = vim.fn.filereadable(venv_path .. '/bin/python') == 1
  if python_exists then
    print('   ✓ Python executable found')
  else
    print('   ✗ Python executable not found in venv')
  end
else
  print('   ✗ MCP not installed (run :ClaudeInstallMCP)')
end

print('\n=== Installation test complete ===')
print('\nNext steps:')
print('1. If any dependencies are missing, install them')
print('2. Run :ClaudeInstallMCP to install the MCP server')
print('3. Run :ClaudeShowMCPCommand to get the setup command')
print('4. Run :ClaudeDebugInstall for more detailed diagnostics')