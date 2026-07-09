-- Events facade: small, public API for event handling
-- NOTE (tests): This façade is covered by E2E tests.
-- Changing these public function signatures or semantics requires updating tests/e2e_spec.lua.

local M = {}

local core = require 'nvim-claude.events.core'
local review_state = require 'nvim-claude.review_state'
local installer = require 'nvim-claude.events.installer'
local autocmds = require 'nvim-claude.events.autocmds'
local commands = require 'nvim-claude.events.commands'

-- Public event handlers
function M.pre_tool_use(file_path, opts) return core.pre_tool_use(file_path, opts) end
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
  return review_state.get_turn_files(git_root)
end

function M.clear_edited_files(git_root)
  return review_state.clear_edited_files(git_root)
end

function M.clear_turn_files(git_root)
  return review_state.clear_turn_files(git_root)
end

function M.list_edited_files(git_root)
  return review_state.list_edited_files(git_root)
end

function M.add_edited_file(git_root, relative_path)
  return review_state.add_edited_file(git_root, relative_path)
end

function M.remove_edited_file(git_root, relative_path)
  return review_state.remove_edited_file(git_root, relative_path)
end

function M.is_edited_file(git_root, relative_path)
  return review_state.is_edited_file(git_root, relative_path)
end

return M
