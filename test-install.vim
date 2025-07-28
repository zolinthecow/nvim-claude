" Quick test file for nvim-claude installation
" Run with: nvim -u test-install.vim

" Minimal init
set nocompatible
filetype plugin indent on
syntax enable

" Add the plugin to runtimepath (adjust path if needed)
" For lazy.nvim users:
" set runtimepath+=~/.local/share/nvim/lazy/nvim-claude

" For the test, we'll use the development path
set runtimepath+=~/.config/nvim/lua/nvim-claude

" Try to load the plugin
lua << EOF
local ok, nvim_claude = pcall(require, 'nvim-claude')
if ok then
  print('✓ nvim-claude loaded successfully')
  nvim_claude.setup({})
  
  -- Test commands
  vim.defer_fn(function()
    print('\nTesting commands:')
    
    -- Test ClaudeDebugInstall
    local ok, _ = pcall(vim.cmd, 'ClaudeDebugInstall')
    if ok then
      print('✓ ClaudeDebugInstall works')
    else
      print('✗ ClaudeDebugInstall failed')
    end
    
    -- Show available commands
    print('\nAvailable Claude commands:')
    local commands = vim.api.nvim_get_commands({})
    for name, _ in pairs(commands) do
      if name:match('^Claude') then
        print('  :' .. name)
      end
    end
  end, 100)
else
  print('✗ Failed to load nvim-claude: ' .. tostring(nvim_claude))
  print('\nMake sure the plugin is installed correctly')
  print('For lazy.nvim, check: ~/.local/share/nvim/lazy/nvim-claude')
end
EOF