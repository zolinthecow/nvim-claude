-- Minimal init for running tests
vim.cmd [[set runtimepath+=.]]

-- Disable persistent writes that may fail in CI sandboxes
vim.o.undofile = false
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
-- Ensure a writable undodir in case something enables undofile
local undodir = '/tmp/nvim-claude-test-undodir'
pcall(vim.fn.mkdir, undodir, 'p')
vim.opt.undodir = undodir

-- As an extra guard, disable undofile right before any buffer write
pcall(vim.api.nvim_create_autocmd, { 'BufWritePre' }, {
  callback = function(args)
    pcall(function()
      vim.bo[args.buf].undofile = false
    end)
  end,
})

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
