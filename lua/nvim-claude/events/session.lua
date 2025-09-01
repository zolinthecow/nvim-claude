-- Session helpers (module hosts both multi-turn edited map and per-turn list)

local M = {}

local project_state = require 'nvim-claude.project-state'

-- Edited files map (relative paths -> true) per project (multi-turn)
local function get_edited_map(git_root)
  return project_state.get(git_root, 'claude_edited_files') or {}
end

local function set_edited_map(git_root, map)
  return project_state.set(git_root, 'claude_edited_files', map or {})
end

function M.is_edited_file(git_root, relative_path)
  if not git_root or not relative_path then return false end
  local map = get_edited_map(git_root)
  return map[relative_path] == true
end

function M.add_edited_file(git_root, relative_path)
  if not git_root or not relative_path then return false end
  local map = get_edited_map(git_root)
  map[relative_path] = true
  return set_edited_map(git_root, map)
end

function M.remove_edited_file(git_root, relative_path)
  if not git_root or not relative_path then return false end
  local map = get_edited_map(git_root)
  map[relative_path] = nil
  return set_edited_map(git_root, map)
end

function M.clear_edited_files(git_root)
  if not git_root then return false end
  return set_edited_map(git_root, {})
end

function M.list_edited_files(git_root)
  local map = get_edited_map(git_root)
  local result = {}
  for path, v in pairs(map) do if v then table.insert(result, path) end end
  table.sort(result)
  return result
end

-- Turn-edited absolute file list (stored under legacy key 'session_edited_files')
local function get_turn_list(git_root)
  return project_state.get(git_root, 'session_edited_files') or {}
end

local function set_turn_list(git_root, list)
  return project_state.set(git_root, 'session_edited_files', list or {})
end

function M.add_turn_file(git_root, file_path)
  if not git_root or not file_path or file_path == '' then return false end
  local list = get_turn_list(git_root)
  local seen = {}
  for _, f in ipairs(list) do seen[f] = true end
  if not seen[file_path] then table.insert(list, file_path) end
  return set_turn_list(git_root, list)
end

function M.get_turn_files(git_root)
  local list = get_turn_list(git_root)
  local out = {}
  for _, f in ipairs(list) do if vim.fn.filereadable(f) == 1 then table.insert(out, f) end end
  return out
end

function M.clear_turn_files(git_root)
  return set_turn_list(git_root, {})
end

return M

