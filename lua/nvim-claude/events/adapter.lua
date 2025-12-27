-- Adapter: base64 wrappers for external scripts to call core event handlers

local M = {}

local core = require 'nvim-claude.events.core'
local utils = require 'nvim-claude.utils'

local function decode_b64(s)
  if not s or s == '' then return '' end
  -- Use Neovim's built-in base64 decode to avoid any shell interpretation
  local ok, decoded = pcall(vim.base64.decode, s)
  if ok and decoded then
    return decoded
  end
  -- Fallback: try vim.fn.system but this shouldn't be needed
  return ''
end

-- Pre-tool-use (file path optional)
function M.pre_tool_use_b64(file_path_b64)
  local path = decode_b64(file_path_b64)
  if path == '' then path = nil end
  return core.pre_tool_use(path)
end

-- Post-tool-use (file path optional)
function M.post_tool_use_b64(file_path_b64)
  local path = decode_b64(file_path_b64)
  if path == '' then path = nil end
  return core.post_tool_use(path)
end

-- Track deleted file
function M.track_deleted_file_b64(file_path_b64)
  local path = decode_b64(file_path_b64)
  if path == '' then return true end
  return core.track_deleted_file(path)
end

-- Untrack failed deletion
function M.untrack_failed_deletion_b64(file_path_b64)
  local path = decode_b64(file_path_b64)
  if path == '' then return true end
  return core.untrack_failed_deletion(path)
end

-- User prompt submit (string payload)
function M.user_prompt_submit_b64(prompt_b64)
  local prompt = decode_b64(prompt_b64)
  return core.user_prompt_submit(prompt)
end

-- Clear per-turn session files for a path's project (path b64-encoded)
function M.clear_turn_files_for_path_b64(path_b64)
  local path = decode_b64(path_b64)
  if not path or path == '' then return false end
  local git_root = utils.get_project_root_for_file(path)
  local ok, logger = pcall(require, 'nvim-claude.logger')
  if ok then logger.debug('adapter', 'clear_turn_files_for_path_b64', { path = path, git_root = git_root }) end
  return require('nvim-claude.events').clear_turn_files(git_root)
end

return M
