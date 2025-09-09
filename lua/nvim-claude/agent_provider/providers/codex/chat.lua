-- Codex provider: chat transport via tmux

local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local utils = require 'nvim-claude.utils'
local tmux = utils.tmux

local M = {}

local function ensure_pane()
  local pane = tmux.find_chat_pane()
  if not pane then
    pane = tmux.create_pane(cfg.spawn_command or 'codex')
  end
  return pane
end

function M.ensure_pane()
  return ensure_pane()
end

function M.send_text(text)
  local pane = ensure_pane()
  if not pane then return false end
  return tmux.send_text_to_pane(pane, text)
end

return M

