local M = {}

local utils = require 'nvim-claude.utils'
local logger = require 'nvim-claude.logger'
local project_state = require 'nvim-claude.project-state'

local function resolve_root(project_root)
  local root = project_root or utils.get_project_root()
  if not root or root == '' then return nil end
  return project_state.get_project_key(root)
end

local function read_agents(project_root)
  local root = resolve_root(project_root)
  if not root then return nil, {} end
  local agents = project_state.get(root, 'agent_registry')
  return root, type(agents) == 'table' and agents or {}
end

local function update_agents(project_root, updater)
  local root = resolve_root(project_root)
  if not root then return false end
  return project_state.update_project(root, function(state)
    local agents = type(state.agent_registry) == 'table' and state.agent_registry or {}
    local updated = updater(agents, root)
    if updated == false then return false end
    state.agent_registry = updated or agents
    return state
  end)
end

function M.setup(opts, project_root)
  opts = opts or {}
  local old_registry = opts.legacy_path or (vim.fn.stdpath('data') .. '/nvim-claude/registry.json')
  if not utils.file_exists(old_registry) then return true end

  local content, read_err = utils.read_file(old_registry)
  local decoded_ok, decoded = false, nil
  if content then decoded_ok, decoded = pcall(vim.json.decode, content) end
  local legacy = type(decoded) == 'table' and (decoded.agents or decoded) or nil
  if type(legacy) ~= 'table' then
    logger.error('background_agent.registry', 'Failed to parse legacy registry', {
      path = old_registry,
      error = read_err or decoded,
    })
    return false
  end

  local saved = update_agents(project_root, function(agents)
    for id, agent in pairs(legacy) do
      if agents[id] == nil and type(agent) == 'table' then agents[id] = vim.deepcopy(agent) end
    end
    return agents
  end)
  if not saved then return false end
  return vim.fn.delete(old_registry) == 0
end

function M.load(project_root)
  local _, agents = read_agents(project_root)
  return agents
end

function M.save(project_root, agents)
  if agents == nil and type(project_root) == 'table' then
    agents = project_root
    project_root = nil
  end
  agents = type(agents) == 'table' and vim.deepcopy(agents) or {}
  return update_agents(project_root, function() return agents end)
end

function M.check_window_exists(window_id)
  if not window_id or window_id == '' then return false end
  local output = utils.exec("tmux list-windows -a -F '#{window_id}'")
  if not output then return false end
  for line in output:gmatch('[^\n]+') do
    if line == window_id then return true end
  end
  return false
end

function M.validate_agents(project_root)
  local now = os.time()
  local changed = false
  local saved = update_agents(project_root, function(agents)
    local valid = {}
    for id, agent in pairs(agents) do
      if type(agent) == 'table' and agent.work_dir then
        local mission_exists = utils.file_exists(agent.work_dir .. '/mission.log')
        if mission_exists then
          local copy = vim.deepcopy(agent)
          if copy.status == 'active' then
            if M.check_window_exists(copy.window_id) then
              local progress = utils.read_file(copy.work_dir .. '/progress.txt')
              if progress and progress ~= '' then copy.progress = progress:gsub('\n$', '') end
            else
              copy.status = 'completed'
              copy.end_time = copy.end_time or now
              copy.last_update = now
            end
          end
          valid[id] = copy
        end
      end
    end
    if vim.deep_equal(agents, valid) then return false end
    changed = true
    return valid
  end)
  return not changed or saved
end

function M.register(task, work_dir, window_id, window_name, fork_info, project_root, max_agents)
  local id = string.format('%s-%s', utils.timestamp(), string.format('%.0f', vim.loop.hrtime()):sub(-10))
  local rejected = false
  local saved = update_agents(project_root, function(agents, root)
    if max_agents then
      local active = 0
      for _, agent in pairs(agents) do
        if agent.status == 'active' then active = active + 1 end
      end
      if active >= max_agents then
        rejected = true
        return false
      end
    end
    agents[id] = {
      id = id,
      task = task,
      work_dir = work_dir,
      window_id = window_id,
      window_name = window_name,
      project_root = root,
      start_time = os.time(),
      status = 'active',
      progress = 'Starting...',
      last_update = os.time(),
      fork_info = fork_info,
    }
    return agents
  end)
  if rejected then return nil, 'Agent limit reached' end
  if not saved then return nil, 'Failed to persist agent registry' end
  return id
end

function M.get(id, project_root)
  local _, agents = read_agents(project_root)
  return agents[id]
end

function M.get_project_agents(project_root)
  local _, agents = read_agents(project_root)
  local result = {}
  for id, agent in pairs(agents) do
    local copy = vim.deepcopy(agent)
    copy._registry_id = id
    table.insert(result, copy)
  end
  return result
end

function M.get_active_count(project_root)
  local _, agents = read_agents(project_root)
  local count = 0
  for _, agent in pairs(agents) do
    if agent.status == 'active' then count = count + 1 end
  end
  return count
end

function M.update_status(id, status, project_root)
  local found = false
  local saved = update_agents(project_root, function(agents)
    local agent = agents[id]
    if not agent then return false end
    found = true
    agent.status = status
    if status == 'completed' or status == 'failed' or status == 'killed' then
      agent.end_time = os.time()
    end
    agent.last_update = os.time()
    return agents
  end)
  return found and saved
end

function M.update_progress(id, progress, project_root)
  local found = false
  local saved = update_agents(project_root, function(agents)
    local agent = agents[id]
    if not agent then return false end
    found = true
    agent.progress = progress
    agent.last_update = os.time()
    return agents
  end)
  return found and saved
end

function M.remove(id, project_root)
  local found = false
  local saved = update_agents(project_root, function(agents)
    if not agents[id] then return false end
    found = true
    agents[id] = nil
    return agents
  end)
  return found and saved
end

function M.cleanup(days, project_root)
  if not days or days < 0 then return 0 end
  local root, agents = read_agents(project_root)
  if not root then return 0 end
  local cutoff = os.time() - (days * 24 * 60 * 60)
  local removed = 0
  for id, agent in pairs(agents) do
    if agent.status ~= 'active' and agent.end_time and agent.end_time < cutoff then
      local worktree_removed = true
      if agent.work_dir and utils.file_exists(agent.work_dir) then
        worktree_removed = utils.git.remove_worktree(agent.work_dir, root)
      end
      if worktree_removed and M.remove(id, root) then removed = removed + 1 end
    end
  end
  return removed
end

function M.format_agent(agent)
  local age = os.difftime(os.time(), agent.start_time or os.time())
  local age_string
  if age < 60 then
    age_string = string.format('%ds', age)
  elseif age < 3600 then
    age_string = string.format('%dm', math.floor(age / 60))
  elseif age < 86400 then
    age_string = string.format('%dh', math.floor(age / 3600))
  else
    age_string = string.format('%dd', math.floor(age / 86400))
  end

  local progress = ''
  if agent.progress and agent.status == 'active' then progress = ' | ' .. agent.progress end
  local task = tostring(agent.task or 'Unknown task'):match('[^\n]*') or 'Unknown task'
  if #task > 50 then task = task:sub(1, 50) .. '...' end
  return string.format(
    '[%s] %s (%s) - %s%s',
    tostring(agent.status or 'unknown'):upper(),
    task,
    age_string,
    agent.window_name or 'unknown',
    progress
  )
end

return M
