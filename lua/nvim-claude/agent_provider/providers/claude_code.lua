-- Claude Code provider: delegates to existing hook installer and tmux chat

local M = {}

M.name = 'claude'

function M.install_hooks()
  -- Reuse existing installer that writes .claude/settings.local.json
  return require('nvim-claude.events').install_hooks()
end

function M.uninstall_hooks()
  return require('nvim-claude.events').uninstall_hooks()
end

-- Chat transport via tmux; mirrors current behavior
M.chat = {}

local function ensure_pane()
  local utils = require('nvim-claude.utils')
  local tmux = utils.tmux
  local pane = tmux.find_claude_pane()
  if not pane then
    pane = tmux.create_pane('claude')
  end
  return pane
end

function M.chat.ensure_pane()
  return ensure_pane()
end

function M.chat.send_text(text)
  local utils = require('nvim-claude.utils')
  local tmux = utils.tmux
  local pane = ensure_pane()
  if not pane then return false end
  return tmux.send_text_to_pane(pane, text)
end

return M

