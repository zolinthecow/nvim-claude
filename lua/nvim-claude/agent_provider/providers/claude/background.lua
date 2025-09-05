-- Claude provider: background agent pane helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux

local M = {}
local cfg = require('nvim-claude.agent_provider.providers.claude.config')

function M.launch_agent_pane(window_id, cwd, initial_text)
  if not window_id then
    return nil
  end
  local pane_id = tmux.split_window(window_id, 'h', 40)
  if not pane_id then
    return nil
  end
  tmux.send_to_pane(pane_id, 'cd ' .. cwd)
  tmux.send_to_pane(pane_id, cfg.background_spawn or 'claude --dangerously-skip-permissions')
  vim.defer_fn(function()
    if initial_text and initial_text ~= '' then
      tmux.send_text_to_pane(pane_id, initial_text)
    end
  end, 1000)
  return pane_id
end

return M
