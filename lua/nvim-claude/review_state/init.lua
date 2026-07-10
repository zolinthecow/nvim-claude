local M = {}

local project_state = require 'nvim-claude.project-state'

local function normalize_root(git_root)
  if type(git_root) ~= 'string' or git_root == '' then return nil end
  return project_state.get_project_key(git_root)
end

local function normalize_relative_path(git_root, path)
  local root = normalize_root(git_root)
  if not root or type(path) ~= 'string' or path == '' then return nil end
  local absolute = path
  if absolute:sub(1, 1) ~= '/' then absolute = root .. '/' .. absolute end
  absolute = vim.fn.resolve(vim.fn.fnamemodify(absolute, ':p'))
  if absolute:sub(1, #root + 1) ~= root .. '/' then return nil end
  local relative = absolute:sub(#root + 2):gsub('\\', '/')
  if relative == '' or relative == '.' or relative:match '^%.%./' then return nil end
  return root, relative
end

local function normalize_absolute_path(git_root, path)
  local root, relative = normalize_relative_path(git_root, path)
  if not root then return nil end
  return root, root .. '/' .. relative
end

local function normalize_edited_map(raw)
  if type(raw) ~= 'table' then return {} end

  local is_list
  if type(vim.islist) == 'function' then
    is_list = vim.islist(raw)
  elseif type(vim.tbl_islist) == 'function' then
    is_list = vim.tbl_islist(raw)
  end
  if not is_list then return raw end

  local map = {}
  for _, path in ipairs(raw) do
    if type(path) == 'string' and path ~= '' then map[path] = true end
  end
  return map
end

local function get_edited_map(git_root)
  git_root = normalize_root(git_root)
  if not git_root then return {} end
  return normalize_edited_map(project_state.get(git_root, 'claude_edited_files'))
end

local function update_edited_map(git_root, updater)
  git_root = normalize_root(git_root)
  if not git_root then return false end
  return project_state.update_project(git_root, function(state)
    local map = normalize_edited_map(state.claude_edited_files)
    updater(map)
    state.claude_edited_files = next(map) and map or vim.empty_dict()
    return state
  end)
end

function M.is_edited_file(git_root, relative_path)
  local root, normalized = normalize_relative_path(git_root, relative_path)
  if not root then return false end
  return get_edited_map(root)[normalized] == true
end

function M.add_edited_file(git_root, relative_path)
  local root, normalized = normalize_relative_path(git_root, relative_path)
  if not root then return false end
  return update_edited_map(root, function(map) map[normalized] = true end)
end

function M.remove_edited_files(git_root, relative_paths)
  local root = normalize_root(git_root)
  if not root then return false end
  local normalized_paths = {}
  for _, relative_path in ipairs(relative_paths or {}) do
    local path_root, normalized = normalize_relative_path(root, relative_path)
    if not path_root then return false end
    table.insert(normalized_paths, normalized)
  end
  return update_edited_map(root, function(map)
    for _, relative_path in ipairs(normalized_paths) do map[relative_path] = nil end
  end)
end

function M.remove_edited_file(git_root, relative_path)
  if not relative_path then return false end
  return M.remove_edited_files(git_root, { relative_path })
end

function M.clear_edited_files(git_root)
  git_root = normalize_root(git_root)
  if not git_root then return false end
  return update_edited_map(git_root, function(map)
    for path in pairs(map) do map[path] = nil end
  end)
end

function M.clear(git_root)
  git_root = normalize_root(git_root)
  if not git_root then return false end
  return project_state.update_project(git_root, function(state)
    state.claude_edited_files = vim.empty_dict()
    state.session_edited_files = {}
    return state
  end)
end

function M.list_edited_files(git_root)
  git_root = normalize_root(git_root)
  if not git_root then return {} end
  local result = {}
  for path, enabled in pairs(get_edited_map(git_root)) do
    if enabled then table.insert(result, path) end
  end
  table.sort(result)
  return result
end

local function get_turn_list(git_root)
  git_root = normalize_root(git_root)
  if not git_root then return {} end
  return project_state.get(git_root, 'session_edited_files') or {}
end

function M.add_turn_file(git_root, file_path)
  local root, absolute = normalize_absolute_path(git_root, file_path)
  if not root then return false end
  return project_state.update_project(root, function(state)
    local list = state.session_edited_files or {}
    if not vim.tbl_contains(list, absolute) then table.insert(list, absolute) end
    state.session_edited_files = list
    return state
  end)
end

function M.get_turn_files(git_root)
  local result = {}
  for _, file_path in ipairs(get_turn_list(git_root)) do
    if vim.fn.filereadable(file_path) == 1 then table.insert(result, file_path) end
  end
  return result
end

function M.clear_turn_files(git_root)
  if not git_root or git_root == '' then
    local ok, utils = pcall(require, 'nvim-claude.utils')
    if ok then git_root = utils.get_project_root() end
  end
  git_root = normalize_root(git_root)
  if not git_root then return false end
  return project_state.update_project(git_root, function(state)
    state.session_edited_files = {}
    return state
  end)
end

return M
