-- RPC client install command

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register()
  define('ClaudeInstallRPC', function()
    local plugin_dir = require('nvim-claude').get_plugin_dir()
    if not plugin_dir then
      vim.notify('nvim-claude: Could not find plugin directory. Please report this issue.', vim.log.levels.ERROR)
      return
    end
    local install_script = plugin_dir .. 'rpc/install.sh'
    if vim.fn.filereadable(install_script) == 0 then
      vim.notify('nvim-claude: RPC install script not found at: ' .. install_script, vim.log.levels.ERROR)
      return
    end
    local function on_exit(_, code, _)
      if code == 0 then
        vim.notify('✅ RPC client installed successfully!', vim.log.levels.INFO)
        vim.notify('Hooks will now use the Python RPC client', vim.log.levels.INFO)
      else
        vim.notify('❌ RPC installation failed. Check :messages for details', vim.log.levels.ERROR)
      end
    end
    vim.notify('Installing RPC client dependencies...', vim.log.levels.INFO)
    vim.fn.jobstart({ 'bash', install_script }, {
      on_exit = on_exit,
      on_stdout = function(_, data)
        for _, line in ipairs(data) do if line ~= '' then print(line) end end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do if line ~= '' then vim.notify(line, vim.log.levels.WARN) end end
      end,
    })
  end, { desc = 'Install nvim-claude RPC client (pynvim)' })
end

return M

