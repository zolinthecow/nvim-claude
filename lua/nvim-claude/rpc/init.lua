-- RPC client management (install/ensure)

local M = {}

local function plugin_dir()
  local src = debug.getinfo(1, 'S').source:sub(2)
  local root = src:match('(.*/)lua/nvim%-claude/')
  if root and vim.fn.isdirectory(root .. 'rpc') == 1 then return root end
  local lazy = vim.fn.stdpath('data') .. '/lazy/nvim-claude/'
  if vim.fn.isdirectory(lazy .. 'rpc') == 1 then return lazy end
  local packer = vim.fn.stdpath('data') .. '/site/pack/packer/start/nvim-claude/'
  if vim.fn.isdirectory(packer .. 'rpc') == 1 then return packer end
  local dev = vim.fn.expand('~/.config/nvim/lua/nvim-claude/')
  if vim.fn.isdirectory(dev .. 'rpc') == 1 then return dev end
  return nil
end

local function install_script_path()
  local root = plugin_dir()
  return root and (root .. 'rpc/install.sh') or nil
end

function M.install()
  local script = install_script_path()
  if not script or vim.fn.filereadable(script) == 0 then
    vim.notify('nvim-claude: RPC install script not found', vim.log.levels.ERROR)
    return false
  end
  vim.notify('Installing RPC client dependencies...', vim.log.levels.INFO)
  vim.fn.jobstart({ 'bash', script }, {
    on_exit = function(_, code)
      if code == 0 then
        vim.notify('✅ RPC client installed successfully', vim.log.levels.INFO)
      else
        vim.notify('❌ RPC installation failed. Check :messages for details', vim.log.levels.ERROR)
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do if line ~= '' then vim.notify(line, vim.log.levels.WARN) end end
    end,
  })
  return true
end

function M.ensure_installed()
  local venv = vim.env.NVIM_CLAUDE_RPC_ENV
  if not venv or venv == '' then
    local xdg = vim.env.XDG_DATA_HOME
    if xdg and xdg ~= '' then
      venv = xdg .. '/nvim/nvim-claude/rpc-env'
    else
      venv = vim.fn.expand('~/.local/share/nvim/nvim-claude/rpc-env')
    end
  end
  local py = venv .. '/bin/python'
  if vim.fn.filereadable(py) == 1 then
    local _ = vim.fn.system(string.format('%s -c "import pynvim" 2>/dev/null', py))
    if vim.v.shell_error == 0 then return true end
  end
  return M.install()
end

return M

