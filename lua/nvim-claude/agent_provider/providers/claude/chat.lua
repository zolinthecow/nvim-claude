-- Claude provider: chat transport via tmux

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux

local M = {}

local function ensure_pane()
  local pane = tmux.find_claude_pane()
  if not pane then
    pane = tmux.create_pane 'claude'
  end
  return pane
end

function M.ensure_pane()
  return ensure_pane()
end

function M.send_text(text)
  local pane = ensure_pane()
  if not pane then
    return false
  end
  return tmux.send_text_to_pane(pane, text)
end

return M
