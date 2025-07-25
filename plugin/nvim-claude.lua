-- This file is automatically loaded by Neovim
-- It ensures the plugin is available but doesn't force setup

if vim.g.loaded_nvim_claude then
  return
end
vim.g.loaded_nvim_claude = true

-- Make the plugin available but don't auto-setup
-- Users should call require('nvim-claude').setup() in their config