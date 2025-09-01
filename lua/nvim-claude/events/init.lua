-- Events facade: small, public API for event handling

local M = {}

local core = require 'nvim-claude.events.core'
local session = require 'nvim-claude.events.session'
local installer = require 'nvim-claude.events.installer'
local autocmds = require 'nvim-claude.events.autocmds'
local commands = require 'nvim-claude.events.commands'

-- Public event handlers
function M.pre_tool_use(file_path) return core.pre_tool_use(file_path) end
function M.post_tool_use(file_path) return core.post_tool_use(file_path) end
function M.track_deleted_file(file_path) return core.track_deleted_file(file_path) end
function M.untrack_failed_deletion(file_path) return core.untrack_failed_deletion(file_path) end
function M.user_prompt_submit(prompt) return core.user_prompt_submit(prompt) end

-- Hook installer
function M.install_hooks() return installer.install() end
function M.uninstall_hooks() return installer.uninstall() end

-- Setup default autocmds and user commands
function M.setup()
  commands.setup()
  autocmds.setup()
end

-- Minimal public session helpers
function M.get_turn_files(git_root)
  return session.get_turn_files(git_root)
end

return M
