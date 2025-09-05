-- Claude provider: composes hooks, chat, and background helpers

local M = {}

M.name = 'claude'

local hooks = require('nvim-claude.agent_provider.providers.claude.hooks')
local chat = require('nvim-claude.agent_provider.providers.claude.chat')
local background = require('nvim-claude.agent_provider.providers.claude.background')

M.install_hooks = hooks.install
M.uninstall_hooks = hooks.uninstall

-- Explicitly export chat surface
M.chat = {
  ensure_pane = function()
    return chat.ensure_pane()
  end,
  send_text = function(text)
    return chat.send_text(text)
  end,
}

-- Explicitly export background helpers
M.background = {
  launch_agent_pane = function(window_id, cwd, initial_text)
    return background.launch_agent_pane(window_id, cwd, initial_text)
  end,
}

return M
