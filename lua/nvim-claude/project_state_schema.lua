-- Project-state schema normalization helpers.
-- Keeps persisted state shape stable across JSON (and future DB backends).

local M = {}

local function is_list(tbl)
  if type(tbl) ~= 'table' then
    return false
  end
  if type(vim.islist) == 'function' then
    return vim.islist(tbl)
  end
  local legacy = rawget(vim, 'tbl_islist')
  if type(legacy) == 'function' then
    return legacy(tbl)
  end
  return false
end

local function normalize_sha(value)
  if type(value) ~= 'string' then
    return nil
  end
  local trimmed = value:gsub('%s+', ''):lower()
  if trimmed == '' then
    return nil
  end
  if not trimmed:match('^[a-f0-9]+$') then
    return nil
  end
  return trimmed
end

local function normalize_relative_path(path, project_root)
  if type(path) ~= 'string' then
    return nil
  end

  local value = vim.trim(path)
  if value == '' then
    return nil
  end

  value = value:gsub('\\', '/'):gsub('//+', '/')

  if value:match('^[%a][%w+.-]*:') then
    return nil
  end

  if project_root and value:sub(1, 1) == '/' then
    local resolved_value = vim.fn.resolve(vim.fn.expand(value))
    local resolved_root = vim.fn.resolve(vim.fn.expand(project_root))
    if type(resolved_value) == 'string' and type(resolved_root) == 'string' and resolved_value:sub(1, #resolved_root + 1) == resolved_root .. '/' then
      value = resolved_value:sub(#resolved_root + 2)
    end
  elseif project_root and value:sub(1, #project_root + 1) == project_root .. '/' then
    value = value:sub(#project_root + 2)
  end

  value = value:gsub('^%./', '')
  if value:sub(1, 1) == '/' then
    return nil
  end
  if value == '.' or value == '..' or value:match('^%.%./') then
    return nil
  end
  if value == '' then
    return nil
  end

  return value
end

local function normalize_absolute_path(path, project_root)
  if type(path) ~= 'string' then
    return nil
  end

  local value = vim.trim(path)
  if value == '' then
    return nil
  end

  if value:match('^[%a][%w+.-]*:') then
    return nil
  end

  if value:sub(1, 1) ~= '/' then
    if not project_root then
      return nil
    end
    value = project_root .. '/' .. value
  end

  value = vim.fn.resolve(vim.fn.expand(value))
  if type(value) ~= 'string' or value == '' then
    return nil
  end
  return value
end

local function normalize_edited_files_map(raw, project_root)
  local map = {}

  if type(raw) == 'table' then
    if is_list(raw) then
      for _, value in ipairs(raw) do
        local rel = normalize_relative_path(value, project_root)
        if rel then
          map[rel] = true
        end
      end
    else
      for rel, enabled in pairs(raw) do
        if enabled then
          local normalized = normalize_relative_path(rel, project_root)
          if normalized then
            map[normalized] = true
          end
        end
      end
    end
  end

  if next(map) == nil then
    return vim.empty_dict()
  end

  return map
end

local function normalize_turn_files(raw, project_root)
  local out = {}
  local seen = {}

  local function add(path)
    local abs = normalize_absolute_path(path, project_root)
    if abs and not seen[abs] then
      seen[abs] = true
      table.insert(out, abs)
    end
  end

  if type(raw) == 'table' then
    if is_list(raw) then
      for _, value in ipairs(raw) do
        add(value)
      end
    else
      for path, enabled in pairs(raw) do
        if enabled then
          add(path)
        end
      end
    end
  end

  return out
end

local function normalize_inline_diff_state(raw)
  if type(raw) ~= 'table' or is_list(raw) then
    return nil
  end

  local out = vim.deepcopy(raw)
  local baseline_ref = normalize_sha(out.baseline_ref or out.stash_ref)
  out.baseline_ref = baseline_ref
  out.stash_ref = nil

  if out.timestamp ~= nil then
    local ts = tonumber(out.timestamp)
    out.timestamp = ts and math.floor(ts) or nil
  end

  if next(out) == nil then
    return nil
  end

  return out
end

local function merge_entries(existing, incoming)
  if not existing then
    return incoming
  end
  if not incoming then
    return existing
  end

  local merged = vim.tbl_deep_extend('force', vim.deepcopy(existing), incoming)

  local existing_inline = existing.inline_diff_state
  local incoming_inline = incoming.inline_diff_state
  if existing_inline and incoming_inline then
    local existing_ts = tonumber(existing_inline.timestamp) or 0
    local incoming_ts = tonumber(incoming_inline.timestamp) or 0
    merged.inline_diff_state = incoming_ts >= existing_ts and incoming_inline or existing_inline
  end

  local merged_map = normalize_edited_files_map(existing.claude_edited_files)
  for rel, enabled in pairs(normalize_edited_files_map(incoming.claude_edited_files)) do
    if enabled then
      merged_map[rel] = true
    end
  end
  merged.claude_edited_files = next(merged_map) and merged_map or vim.empty_dict()

  local seen = {}
  local merged_turn = {}
  for _, path in ipairs(existing.session_edited_files or {}) do
    if not seen[path] then
      seen[path] = true
      table.insert(merged_turn, path)
    end
  end
  for _, path in ipairs(incoming.session_edited_files or {}) do
    if not seen[path] then
      seen[path] = true
      table.insert(merged_turn, path)
    end
  end
  merged.session_edited_files = merged_turn

  local existing_last = tonumber(existing.last_accessed) or 0
  local incoming_last = tonumber(incoming.last_accessed) or 0
  merged.last_accessed = math.max(existing_last, incoming_last)

  return merged
end

function M.normalize_project_entry(entry, project_root)
  local input = type(entry) == 'table' and entry or {}
  if is_list(input) then
    input = {}
  end

  local out = {}

  for key, value in pairs(input) do
    if key ~= 'inline_diff_state' and key ~= 'claude_edited_files' and key ~= 'session_edited_files' and key ~= 'last_accessed' then
      out[key] = value
    end
  end

  local inline = normalize_inline_diff_state(input.inline_diff_state)
  if inline ~= nil then
    out.inline_diff_state = inline
  end

  out.claude_edited_files = normalize_edited_files_map(input.claude_edited_files, project_root)
  out.session_edited_files = normalize_turn_files(input.session_edited_files, project_root)

  local last_accessed = tonumber(input.last_accessed)
  if last_accessed and last_accessed > 0 then
    out.last_accessed = math.floor(last_accessed)
  end

  return out
end

function M.normalize_all_states(states, normalize_project_key)
  if type(states) ~= 'table' or is_list(states) then
    return {}, true
  end

  local normalized = {}

  for raw_key, raw_entry in pairs(states) do
    local key = type(raw_key) == 'string' and raw_key or tostring(raw_key)
    local project_key = nil

    if normalize_project_key and type(normalize_project_key) == 'function' then
      local ok, value = pcall(normalize_project_key, key)
      if ok then
        project_key = value
      end
    else
      project_key = key
    end

    if project_key and project_key ~= '' then
      local entry = M.normalize_project_entry(raw_entry, project_key)
      normalized[project_key] = merge_entries(normalized[project_key], entry)
    elseif key:sub(1, 2) == '__' then
      -- Preserve non-project global keys (e.g. provider metadata).
      normalized[key] = raw_entry
    end
  end

  local changed = not vim.deep_equal(states, normalized)
  return normalized, changed
end

return M
