-- Claude provider: composes hooks, chat, and background helpers

local M = {}

M.name = 'claude'

local cfg = require('nvim-claude.agent_provider.providers.claude.config')
local hooks = require('nvim-claude.agent_provider.providers.claude.hooks')
local chat = require('nvim-claude.agent_provider.providers.claude.chat')
local background = require('nvim-claude.agent_provider.providers.claude.background')

function M.setup(opts)
  cfg.setup(opts)
end

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
  ensure_targeted_pane = function(initial_text)
    return chat.ensure_targeted_pane(initial_text)
  end,
  send_targeted_text = function(text)
    return chat.send_targeted_text(text)
  end,
  get_targeted_pane = function()
    return chat.get_targeted_pane()
  end,
}

-- Explicitly export background helpers
M.background = {
  launch_agent_pane = function(window_id, cwd, initial_text)
    return background.launch_agent_pane(window_id, cwd, initial_text)
  end,
}

return M
