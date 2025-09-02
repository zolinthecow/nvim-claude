-- Checkpoint commands

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register()
  local checkpoint = require('nvim-claude.checkpoint')

  define('ClaudeCheckpoints', function()
    local checkpoints = checkpoint.list_checkpoints()
    if #checkpoints == 0 then vim.notify('No checkpoints found', vim.log.levels.INFO); return end
    local items = {}
    for _, cp in ipairs(checkpoints) do
      table.insert(items, string.format('%s | %s', os.date('%Y-%m-%d %H:%M:%S', cp.timestamp), cp.prompt))
    end
    vim.ui.select(items, { prompt = 'Select checkpoint to restore:' }, function(choice, idx)
      if choice and idx then checkpoint.restore_checkpoint(checkpoints[idx].id) end
    end)
  end, { desc = 'Open checkpoint browser' })

  define('ClaudeCheckpointCreate', function(opts)
    local id = checkpoint.create_checkpoint((opts and opts.args) or 'Manual checkpoint')
    if id then vim.notify('Created checkpoint: ' .. id, vim.log.levels.INFO) else vim.notify('Failed to create checkpoint', vim.log.levels.ERROR) end
  end, { desc = 'Create a checkpoint manually', nargs = '?' })

  define('ClaudeCheckpointRestore', function(opts)
    local ok = checkpoint.restore_checkpoint(opts.args)
    if ok then vim.notify('Restored checkpoint: ' .. opts.args, vim.log.levels.INFO) else vim.notify('Failed to restore checkpoint', vim.log.levels.ERROR) end
  end, { desc = 'Restore a specific checkpoint', nargs = 1 })

  define('ClaudeCheckpointStatus', function()
    if checkpoint.is_preview_mode() then
      local s = checkpoint.get_status() or {}
      vim.notify(string.format('Preview mode active\nCheckpoint: %s\nOriginal ref: %s\nStash: %s', s.preview_checkpoint or 'unknown', s.original_ref or 'unknown', s.preview_stash or 'none'), vim.log.levels.INFO)
    else
      local list = checkpoint.list_checkpoints()
      vim.notify(string.format('Working mode\nTotal checkpoints: %d', #list), vim.log.levels.INFO)
    end
  end, { desc = 'Show current checkpoint status' })

  define('ClaudeCheckpointAccept', function()
    if checkpoint.accept_checkpoint() then vim.notify('Checkpoint accepted', vim.log.levels.INFO) else vim.notify('Not in preview mode', vim.log.levels.WARN) end
  end, { desc = 'Accept current preview checkpoint' })

  define('ClaudeCheckpointReturn', function()
    if checkpoint.exit_preview_mode() then vim.notify('Returned to original state', vim.log.levels.INFO) else vim.notify('Not in preview mode', vim.log.levels.WARN) end
  end, { desc = 'Return to original state (exit preview)' })
end

return M
