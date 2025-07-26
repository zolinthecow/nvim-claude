-- Keybinding mappings for nvim-claude
local M = {}

function M.setup(config, commands)
  local prefix = config.prefix or '<leader>c'
  
  -- Basic commands
  vim.keymap.set('n', prefix .. 'c', ':ClaudeChat<CR>', {
    desc = 'Open Claude chat',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 's', ':ClaudeSendBuffer<CR>', {
    desc = 'Send buffer to Claude',
    silent = true
  })
  
  vim.keymap.set('v', prefix .. 'v', ':ClaudeSendSelection<CR>', {
    desc = 'Send selection to Claude',
    silent = true
  })
  
  vim.keymap.set('v', prefix .. 'd', ':ClaudeSendWithDiagnostics<CR>', {
    desc = 'Send selection with diagnostics to Claude',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'h', ':ClaudeSendHunk<CR>', {
    desc = 'Send git hunk to Claude',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'b', ':ClaudeBg<CR>', {
    desc = 'Start background agent',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'l', ':ClaudeAgents<CR>', {
    desc = 'List agents',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'k', ':ClaudeKill<CR>', {
    desc = 'Kill agent',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'x', ':ClaudeClean<CR>', {
    desc = 'Clean old agents',
    silent = true
  })
  
  -- Checkpoint commands
  vim.keymap.set('n', prefix .. 'p', ':ClaudeCheckpoints<CR>', {
    desc = 'Browse checkpoints',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'ps', ':ClaudeCheckpointStatus<CR>', {
    desc = 'Checkpoint status',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'pa', ':ClaudeCheckpointAccept<CR>', {
    desc = 'Accept checkpoint',
    silent = true
  })
  
  vim.keymap.set('n', prefix .. 'pr', ':ClaudeCheckpointReturn<CR>', {
    desc = 'Return from checkpoint',
    silent = true
  })
  
  -- Register with which-key if available
  local ok, which_key = pcall(require, 'which-key')
  if ok and which_key.add then
    -- Use the new which-key spec format
    which_key.add({
      { prefix, group = "claude" },
      { prefix .. "p", group = "checkpoints" },
      { "<leader>i", group = "inline-diffs" },
    })
  end
  
  -- Global keymaps for navigating between files with Claude diffs
  vim.keymap.set('n', ']f', function()
    local inline_diff = require('nvim-claude.inline-diff')
    inline_diff.next_diff_file()
  end, {
    desc = 'Next file with Claude diff',
    silent = true
  })
  
  vim.keymap.set('n', '[f', function()
    local inline_diff = require('nvim-claude.inline-diff')
    inline_diff.prev_diff_file()
  end, {
    desc = 'Previous file with Claude diff',
    silent = true
  })
  
  -- Global keymap for listing files with diffs
  vim.keymap.set('n', prefix .. 'i', function()
    local inline_diff = require('nvim-claude.inline-diff')
    inline_diff.list_diff_files()
  end, {
    desc = 'List files with Claude diffs',
    silent = true
  })
  
  -- Note: File-level operations are handled by buffer-local keymaps when viewing diffs
  -- <leader>iA and <leader>iR work on the current file when you have diffs open
  
  -- Global keymap to accept all diffs across all files
  vim.keymap.set('n', '<leader>IA', function()
    local inline_diff = require('nvim-claude.inline-diff')
    inline_diff.accept_all_files()
  end, {
    desc = 'Accept ALL Claude diffs in ALL files',
    silent = true
  })
  
  -- Global keymap to reject all diffs across all files
  vim.keymap.set('n', '<leader>IR', function()
    local inline_diff = require('nvim-claude.inline-diff')
    inline_diff.reject_all_files()
  end, {
    desc = 'Reject ALL Claude diffs in ALL files',
    silent = true
  })
end

return M 