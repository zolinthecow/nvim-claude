-- Global project state management for nvim-claude
local M = {}
local utils = require 'nvim-claude.utils'
local logger = require 'nvim-claude.logger'
local schema = require 'nvim-claude.project_state_schema'
local uv = vim.uv or vim.loop

local state_cache = nil
local state_cache_file = nil
local state_cache_signature = nil
local loaded_snapshots = setmetatable({}, { __mode = 'k' })
local FAILED_SNAPSHOT = {}

local LOCK_TIMEOUT_MS = 3000

local function trim_trailing_slash(path)
  return (path or ''):gsub('/+$', '')
end

local function file_signature(path)
  local stat = uv.fs_stat(path)
  if not stat then return 'missing' end
  local mtime = stat.mtime or {}
  return table.concat({ stat.size or 0, mtime.sec or 0, mtime.nsec or 0 }, ':')
end

local function invalidate_state_cache()
  state_cache = nil
  state_cache_file = nil
  state_cache_signature = nil
end

local function read_states_from_disk(state_file)
  local stat, stat_err, stat_code = uv.fs_stat(state_file)
  if not stat then
    if stat_code == 'ENOENT' then return {} end
    return nil, 'Failed to inspect state file: ' .. tostring(stat_err or stat_code)
  end

  local content, read_err = utils.read_file(state_file)
  if content == nil then
    return nil, 'Failed to read state file: ' .. tostring(read_err or 'unknown error')
  end
  if content == '' then return {} end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= 'table' then
    return nil, 'Failed to parse state file: ' .. tostring(decoded)
  end

  local normalized = schema.normalize_all_states(decoded, M.get_project_key)
  return normalized
end

local function load_cached_states()
  local state_file = M.get_state_file()
  local signature = file_signature(state_file)
  if state_cache and state_cache_file == state_file and state_cache_signature == signature then
    return vim.deepcopy(state_cache)
  end

  local states, err = read_states_from_disk(state_file)
  if not states then return nil, err end

  state_cache = states
  state_cache_file = state_file
  state_cache_signature = signature
  return vim.deepcopy(states)
end

local function atomic_write(path, content)
  utils.ensure_dir(vim.fn.fnamemodify(path, ':h'))
  local suffix = string.format('%d-%d', uv.os_getpid(), uv.hrtime())
  local temp_path = path .. '.tmp.' .. suffix
  local fd, open_err = uv.fs_open(temp_path, 'w', 384)
  if not fd then return false, open_err end

  local ok, write_err = uv.fs_write(fd, content, 0)
  local synced, sync_err = nil, nil
  if ok then synced, sync_err = uv.fs_fsync(fd) end
  uv.fs_close(fd)

  if not ok or not synced then
    uv.fs_unlink(temp_path)
    return false, write_err or sync_err
  end

  local renamed, rename_err = uv.fs_rename(temp_path, path)
  if not renamed then
    uv.fs_unlink(temp_path)
    return false, rename_err
  end
  return true
end

local function acquire_lock(state_file)
  local lock_dir = state_file .. '.lock'
  local owner_file = lock_dir .. '/owner'
  local owner = string.format('%d:%d', uv.os_getpid(), uv.hrtime())
  local started = uv.hrtime()

  local function process_is_alive(pid)
    if pid == uv.os_getpid() then return true end
    local result, err = uv.kill(pid, 0)
    return result == 0 or tostring(err):match('EPERM') ~= nil
  end

  repeat
    local created = uv.fs_mkdir(lock_dir, 448)
    if created then
      local fd, open_err = uv.fs_open(owner_file, 'w', 384)
      if not fd then
        pcall(vim.fn.delete, lock_dir, 'rf')
        return nil, 'Failed to record project-state lock owner: ' .. tostring(open_err)
      end
      local written, write_err = uv.fs_write(fd, owner, 0)
      uv.fs_close(fd)
      if not written then
        pcall(vim.fn.delete, lock_dir, 'rf')
        return nil, 'Failed to record project-state lock owner: ' .. tostring(write_err)
      end
      return function()
        local current_owner = utils.read_file(owner_file)
        if current_owner == owner then pcall(vim.fn.delete, lock_dir, 'rf') end
      end
    end

    local current_owner = utils.read_file(owner_file)
    local owner_pid = current_owner and tonumber(current_owner:match('^(%d+):')) or nil
    if owner_pid and not process_is_alive(owner_pid) then
      if utils.read_file(owner_file) == current_owner then
        pcall(vim.fn.delete, lock_dir, 'rf')
      end
    end
    vim.wait(10, function() return false end)
  until (uv.hrtime() - started) / 1e6 >= LOCK_TIMEOUT_MS

  return nil, 'Timed out waiting for project-state lock'
end

local function mutate_states(mutator)
  local state_file = M.get_state_file()
  utils.ensure_dir(vim.fn.fnamemodify(state_file, ':h'))
  local release, lock_err = acquire_lock(state_file)
  if not release then
    logger.error('project_state', lock_err, { state_file = state_file })
    return false
  end

  local ran, saved, operation_err = xpcall(function()
    invalidate_state_cache()
    local states, read_err = read_states_from_disk(state_file)
    if not states then return false, read_err end

    if mutator(states) == false then return false end

    local next_states = schema.normalize_all_states(states, M.get_project_key)
    local content = vim.json.encode(next_states)
    local written, write_err = atomic_write(state_file, content)
    if written then
      state_cache = vim.deepcopy(next_states)
      state_cache_file = state_file
      state_cache_signature = file_signature(state_file)
    end
    return written, write_err, next_states
  end, debug.traceback)
  release()

  if not ran then
    logger.error('project_state', 'State mutation failed', { error = saved })
    return false
  end
  if not saved then
    if operation_err then
      logger.error('project_state', 'Failed to persist state', { error = operation_err })
    end
    return false
  end

  return true
end

local DELETE = {}

local function is_nonempty_list(value)
  if type(value) ~= 'table' then return false end
  if next(value) == nil then return false end
  if type(vim.islist) == 'function' then return vim.islist(value) end
  return vim.tbl_islist(value)
end

local function apply_snapshot_delta(current, before, after)
  if vim.deep_equal(before, after) then return vim.deepcopy(current) end
  if after == nil then return DELETE end

  if type(before) == 'table'
      and type(after) == 'table'
      and not is_nonempty_list(before)
      and not is_nonempty_list(after)
  then
    local result = type(current) == 'table' and not is_nonempty_list(current)
        and vim.deepcopy(current)
      or {}
    local keys = {}
    for key in pairs(before) do keys[key] = true end
    for key in pairs(after) do keys[key] = true end
    for key in pairs(keys) do
      local value = apply_snapshot_delta(result[key], before[key], after[key])
      result[key] = value == DELETE and nil or value
    end
    return next(result) and result or vim.empty_dict()
  end

  return vim.deepcopy(after)
end

-- Get the global state directory
function M.get_global_state_dir()
  local dir = vim.fn.stdpath('data') .. '/nvim-claude/projects'
  utils.ensure_dir(dir)
  return dir
end

-- Get normalized project key from path
function M.get_project_key(project_root)
  if type(project_root) ~= 'string' or project_root == '' then
    return nil
  end

  if project_root:sub(1, 2) == '__' then
    return nil
  end

  -- Reject URI-like pseudo paths (e.g. fugitive:/...)
  if project_root:match('^[%a][%w+.-]*:') then
    return nil
  end

  local normalized = trim_trailing_slash(vim.fn.resolve(vim.fn.expand(project_root)))
  if normalized == '' then
    return nil
  end

  local stat = vim.loop.fs_stat(normalized)
  if not stat then
    return nil
  end

  if stat.type ~= 'directory' then
    normalized = trim_trailing_slash(vim.fn.fnamemodify(normalized, ':h'))
  end
  if normalized == '' or vim.fn.isdirectory(normalized) == 0 then
    return nil
  end

  return utils.get_project_root_for_file(normalized) or normalized
end

-- Get the global state file path
function M.get_state_file()
  return M.get_global_state_dir() .. '/state.json'
end

-- Load all project states
function M.load_all_states()
  local states, err = load_cached_states()
  if states then
    loaded_snapshots[states] = vim.deepcopy(states)
    return states
  end
  logger.error('load_all_states', err)
  local failed = {}
  loaded_snapshots[failed] = FAILED_SNAPSHOT
  return failed
end

-- Save all project states
function M.save_all_states(states)
  local proposed = vim.deepcopy(states or {})
  local snapshot = type(states) == 'table' and loaded_snapshots[states] or nil
  if snapshot == FAILED_SNAPSHOT then
    logger.error('save_all_states', 'Refusing to save state returned from a failed read')
    return false
  end

  local saved = mutate_states(function(current)
    if snapshot then
      local merged = apply_snapshot_delta(current, snapshot, proposed)
      for key in pairs(current) do current[key] = nil end
      for key, value in pairs(merged == DELETE and {} or merged) do current[key] = value end
      return
    end

    for key in pairs(current) do current[key] = nil end
    for key, value in pairs(proposed) do current[key] = value end
  end)
  if saved and snapshot then loaded_snapshots[states] = vim.deepcopy(proposed) end
  return saved
end

-- Get state for current project
function M.get_project_state(project_root)
  local key = M.get_project_key(project_root)
  if not key then
    return nil
  end
  
  local all_states, err = load_cached_states()
  if not all_states then
    logger.error('get_project_state', err)
    return nil
  end
  return all_states[key] and vim.deepcopy(all_states[key]) or nil
end

-- Save state for current project
function M.save_project_state(project_root, state_data)
  return M.update_project(project_root, function(state)
    return vim.tbl_extend('force', state, state_data or {})
  end)
end

-- Generic get/set for any key in project state
function M.get(project_root, key)
  local state = M.get_project_state(project_root)
  return state and vim.deepcopy(state[key]) or nil
end

function M.set(project_root, key, value)
  return M.update_project(project_root, function(state)
    state[key] = value == nil and nil or vim.deepcopy(value)
    return state
  end)
end

function M.update_project(project_root, updater)
  local project_key = M.get_project_key(project_root)
  if not project_key then
    logger.error('update_project', 'No project key available')
    return false
  end

  if type(updater) ~= 'function' then
    logger.error('update_project', 'Updater must be a function')
    return false
  end

  return mutate_states(function(all_states)
    local current = vim.deepcopy(all_states[project_key] or {})
    local updated = updater(current)
    if updated == false then return false end
    if updated ~= nil then current = updated end
    current.last_accessed = os.time()
    all_states[project_key] = current
  end)
end


-- Clean up old project states
function M.cleanup_old_projects(days_threshold)
  days_threshold = days_threshold or 30
  local cutoff_time = os.time() - (days_threshold * 24 * 60 * 60)
  local removed = 0

  local saved = mutate_states(function(all_states)
    for project_path, state in pairs(all_states) do
      if not (type(project_path) == 'string' and project_path:sub(1, 2) == '__') then
        local exists = vim.fn.isdirectory(project_path) == 1
        local last_accessed = state.last_accessed or 0

        if not exists or last_accessed < cutoff_time then
          all_states[project_path] = nil
          removed = removed + 1
          logger.info('cleanup_old_projects', 'Removed old project state', {
            project = project_path,
            exists = exists,
            last_accessed = os.date('%Y-%m-%d', last_accessed),
          })
        end
      end
    end
  end)

  if not saved then return 0 end
  return removed
end

-- List all tracked projects
function M.list_projects()
  local all_states = M.load_all_states()
  local projects = {}
  
  for project_path, state in pairs(all_states) do
    if not (type(project_path) == 'string' and project_path:sub(1, 2) == '__') then
      table.insert(projects, {
        path = project_path,
        last_accessed = state.last_accessed or 0,
        exists = vim.fn.isdirectory(project_path) == 1,
        has_inline_diff = state.inline_diff_state ~= nil,
        has_agents = state.agent_registry ~= nil and next(state.agent_registry) ~= nil
      })
    end
  end
  
  -- Sort by last accessed, most recent first
  table.sort(projects, function(a, b)
    return a.last_accessed > b.last_accessed
  end)
  
  return projects
end

-- Note: Feature-specific helpers (e.g., edited files) live in their packages.

-- Migrate from old local state if exists
function M.migrate_local_state(project_root)
  local old_dir = project_root .. '/.nvim-claude'
  if vim.fn.isdirectory(old_dir) == 0 then
    return false
  end
  
  logger.info('migrate_local_state', 'Found local state to migrate', { project = project_root })

  local migrated = false
  local failed = false
  local files = {
    { path = old_dir .. '/inline-diff-state.json', key = 'inline_diff_state' },
    { path = old_dir .. '/agent-registry.json', key = 'agent_registry' },
    { path = old_dir .. '/checkpoint-state.json', key = 'checkpoint_state' },
  }

  for _, item in ipairs(files) do
    if vim.fn.filereadable(item.path) == 1 then
      local content = utils.read_file(item.path)
      local ok, value = false, nil
      if content then ok, value = pcall(vim.json.decode, content) end
      if ok and type(value) == 'table' and M.set(project_root, item.key, value) then
        vim.fn.delete(item.path)
        migrated = true
        logger.info('migrate_local_state', 'Migrated legacy state', { key = item.key })
      else
        failed = true
        logger.error('migrate_local_state', 'Failed to migrate legacy state', { path = item.path })
      end
    end
  end

  if not failed then
    local remaining = vim.fn.readdir(old_dir)
    if #remaining == 0 then vim.fn.delete(old_dir, 'd') end
  end

  return migrated and not failed
end

function M.clear_cache()
  invalidate_state_cache()
  utils.clear_project_root_cache()
end

return M
