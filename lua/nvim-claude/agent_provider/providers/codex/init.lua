-- Codex provider façade

local M = {}

M.name = 'codex'

local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local hooks = require('nvim-claude.agent_provider.providers.codex.hooks')
local chat = require('nvim-claude.agent_provider.providers.codex.chat')
local background = require('nvim-claude.agent_provider.providers.codex.background')
local otel = require('nvim-claude.agent_provider.providers.codex.otel_listener')
local relay = require('nvim-claude.agent_provider.providers.codex.relay')

function M.setup(opts)
  cfg.setup(opts)
  if cfg.use_daemon then
    relay.ensure_running()
  else
    otel.ensure(cfg.otel_port)
  end
end

M.install_hooks = hooks.install
M.uninstall_hooks = hooks.uninstall

M.chat = {
  ensure_pane = function() return chat.ensure_pane() end,
  send_text = function(text) return chat.send_text(text) end,
  ensure_targeted_pane = function(initial_text) return chat.ensure_targeted_pane(initial_text) end,
  send_targeted_text = function(text) return chat.send_targeted_text(text) end,
  get_targeted_pane = function() return chat.get_targeted_pane() end,
}

M.background = {
  generate_window_name = function() return background.generate_window_name() end,
  append_to_context = function(dir) return background.append_to_context(dir) end,
  launch_agent_pane = function(win, dir, text) return background.launch_agent_pane(win, dir, text) end,
}

return M
