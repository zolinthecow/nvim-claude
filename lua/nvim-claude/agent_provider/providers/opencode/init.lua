-- OpenCode provider: composes hooks, chat, and background helpers

local M = {}

M.name = 'opencode'

local cfg = require('nvim-claude.agent_provider.providers.opencode.config')
local hooks = require('nvim-claude.agent_provider.providers.opencode.hooks')
local chat = require('nvim-claude.agent_provider.providers.opencode.chat')
local background = require('nvim-claude.agent_provider.providers.opencode.background')

function M.setup(opts)
  cfg.setup(opts)
end

function M.debug_info()
  return {
    name = M.name,
    spawn_command = cfg.spawn_command,
    background_spawn = cfg.background_spawn,
    pane_title = cfg.pane_title,
    process_pattern = cfg.process_pattern,
  }
end

M.install_hooks = hooks.install
M.uninstall_hooks = hooks.uninstall

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

M.background = {
  generate_window_name = function()
    return background.generate_window_name()
  end,
  append_to_context = function(dir)
    return background.append_to_context(dir)
  end,
  launch_agent_pane = function(win, dir, text)
    return background.launch_agent_pane(win, dir, text)
  end,
}

return M
