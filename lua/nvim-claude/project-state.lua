-- Global project state management for nvim-claude
local M = {}
local utils = require 'nvim-claude.utils'
local logger = require 'nvim-claude.logger'

-- Get the global state directory
function M.get_global_state_dir()
  local dir = vim.fn.stdpath('data') .. '/nvim-claude/projects'
  utils.ensure_dir(dir)
  return dir
end

-- Get normalized project key from path
function M.get_project_key(project_root)
  if not project_root then
    return nil
  end
  -- Normalize the path
  local normalized = vim.fn.resolve(vim.fn.expand(project_root))
  -- Remove trailing slashes
  normalized = normalized:gsub('/$', '')
  return normalized
end

-- Get the global state file path
function M.get_state_file()
  return M.get_global_state_dir() .. '/state.json'
end

-- Load all project states
function M.load_all_states()
  local state_file = M.get_state_file()
  local content = utils.read_file(state_file)
  
  if not content then
    return {}
  end
  
  local ok, state = pcall(vim.json.decode, content)
  if not ok then
    logger.error('load_all_states', 'Failed to parse state file', { error = state })
    return {}
  end
  
  return state or {}
end

-- Save all project states
function M.save_all_states(states)
  local state_file = M.get_state_file()
  local content = vim.json.encode(states)
  
  if not utils.write_file(state_file, content) then
    logger.error('save_all_states', 'Failed to write state file')
    return false
  end
  
  return true
end

-- Get state for current project
function M.get_project_state(project_root)
  local key = M.get_project_key(project_root)
  if not key then
    return nil
  end
  
  local all_states = M.load_all_states()
  return all_states[key]
end

-- Save state for current project
function M.save_project_state(project_root, state_data)
  local key = M.get_project_key(project_root)
  if not key then
    logger.error('save_project_state', 'No project key available')
    return false
  end
  
  local all_states = M.load_all_states()
  
  -- Update the specific project's state
  all_states[key] = vim.tbl_extend('force', all_states[key] or {}, state_data, {
    last_accessed = os.time()
  })
  
  return M.save_all_states(all_states)
end

-- Generic get/set for any key in project state
function M.get(project_root, key)
  local state = M.get_project_state(project_root)
  return state and state[key] or nil
end

function M.set(project_root, key, value)
  return M.save_project_state(project_root, {
    [key] = value
  })
end


-- Clean up old project states
function M.cleanup_old_projects(days_threshold)
  days_threshold = days_threshold or 30
  local cutoff_time = os.time() - (days_threshold * 24 * 60 * 60)
  
  local all_states = M.load_all_states()
  local removed = 0
  
  for project_path, state in pairs(all_states) do
    -- Check if project still exists
    local exists = vim.fn.isdirectory(project_path) == 1
    
    -- Check last access time
    local last_accessed = state.last_accessed or 0
    
    if not exists or last_accessed < cutoff_time then
      all_states[project_path] = nil
      removed = removed + 1
      logger.info('cleanup_old_projects', 'Removed old project state', {
        project = project_path,
        exists = exists,
        last_accessed = os.date('%Y-%m-%d', last_accessed)
      })
    end
  end
  
  if removed > 0 then
    M.save_all_states(all_states)
  end
  
  return removed
end

-- List all tracked projects
function M.list_projects()
  local all_states = M.load_all_states()
  local projects = {}
  
  for project_path, state in pairs(all_states) do
    table.insert(projects, {
      path = project_path,
      last_accessed = state.last_accessed or 0,
      exists = vim.fn.isdirectory(project_path) == 1,
      has_inline_diff = state.inline_diff_state ~= nil,
      has_agents = state.agent_registry ~= nil and next(state.agent_registry) ~= nil
    })
  end
  
  -- Sort by last accessed, most recent first
  table.sort(projects, function(a, b)
    return a.last_accessed > b.last_accessed
  end)
  
  return projects
end

-- Migrate from old local state if exists
function M.migrate_local_state(project_root)
  local old_dir = project_root .. '/.nvim-claude'
  if vim.fn.isdirectory(old_dir) == 0 then
    return false
  end
  
  logger.info('migrate_local_state', 'Found local state to migrate', { project = project_root })
  
  -- Load old inline diff state
  local old_diff_file = old_dir .. '/inline-diff-state.json'
  if vim.fn.filereadable(old_diff_file) == 1 then
    local content = utils.read_file(old_diff_file)
    if content then
      local ok, old_state = pcall(vim.json.decode, content)
      if ok and old_state then
        M.set(project_root, 'inline_diff_state', old_state)
        logger.info('migrate_local_state', 'Migrated inline diff state')
      end
    end
  end
  
  -- Load old agent registry
  local old_registry_file = old_dir .. '/agent-registry.json'
  if vim.fn.filereadable(old_registry_file) == 1 then
    local content = utils.read_file(old_registry_file)
    if content then
      local ok, old_registry = pcall(vim.json.decode, content)
      if ok and old_registry then
        M.set(project_root, 'agent_registry', old_registry)
        logger.info('migrate_local_state', 'Migrated agent registry')
      end
    end
  end
  
  -- Remove old directory after successful migration
  local remove_cmd = string.format('rm -rf "%s"', old_dir)
  utils.exec(remove_cmd)
  logger.info('migrate_local_state', 'Removed old local state directory')
  
  return true
end

return M