-- Adapter: base64 wrappers for external scripts to call core event handlers

local M = {}

local core = require 'nvim-claude.events.core'

local function decode_b64(s)
  if not s or s == '' then return '' end
  -- Use shell base64 for portability; ensure we don't add trailing newline
  local cmd = string.format("printf '%%s' %s | base64 -d 2>/dev/null", vim.fn.shellescape(s))
  local out = vim.fn.system(cmd)
  out = (out or ''):gsub('\n$', '')
  return out
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

return M
