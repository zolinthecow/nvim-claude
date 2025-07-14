-- Minimal init for running tests
vim.cmd [[set runtimepath+=.]]

-- Add plenary to runtimepath
local plenary_path = vim.fn.stdpath('data') .. '/site/pack/packer/start/plenary.nvim'
if vim.fn.isdirectory(plenary_path) == 0 then
  -- Try common plugin manager paths
  local plugin_paths = {
    vim.fn.stdpath('data') .. '/lazy/plenary.nvim',
    vim.fn.stdpath('data') .. '/plugged/plenary.nvim',
    vim.fn.expand('~/.local/share/nvim/site/pack/*/start/plenary.nvim'),
  }
  
  for _, path in ipairs(plugin_paths) do
    if vim.fn.isdirectory(path) == 1 then
      plenary_path = path
      break
    end
  end
end

vim.opt.runtimepath:append(plenary_path)

-- Ensure the plugin is loaded
require('nvim-claude')