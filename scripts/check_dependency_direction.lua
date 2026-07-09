#!/usr/bin/env nvim -l

local script = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(script, ':h:h')

local packages = {
  app = { allow = '*' },
  core = { allow = { utils = true } },
  utils = { allow = {} },
  review_state = { allow = { core = true, utils = true } },
  inline_diff = { allow = { core = true, review_state = true, utils = true } },
  checkpoint = { allow = { core = true, inline_diff = true, review_state = true, utils = true } },
  agent_provider = { allow = { core = true, inline_diff = true, review_state = true, utils = true } },
  background_agent = { allow = { agent_provider = true, core = true, utils = true } },
  chat = { allow = { agent_provider = true, utils = true } },
  lsp_mcp = { allow = { core = true, review_state = true, utils = true } },
  rpc = { allow = { core = true, utils = true } },
  events = {
    allow = {
      agent_provider = true,
      checkpoint = true,
      core = true,
      inline_diff = true,
      review_state = true,
      utils = true,
    },
  },
  debug = { allow = { agent_provider = true, background_agent = true, core = true, utils = true } },
  cursor_cpp = { allow = { core = true, utils = true } },
}

local top_level_packages = {
  ['init.lua'] = 'app',
  ['mappings.lua'] = 'app',
  ['settings-updater.lua'] = 'app',
  ['statusline.lua'] = 'app',
  ['logger.lua'] = 'core',
  ['project-state.lua'] = 'core',
  ['project_state_schema.lua'] = 'core',
}

local public_modules = {
  ['nvim-claude'] = true,
  ['nvim-claude.commands'] = true,
  ['nvim-claude.logger'] = true,
  ['nvim-claude.mappings'] = true,
  ['nvim-claude.project-state'] = true,
  ['nvim-claude.project_state_schema'] = true,
  ['nvim-claude.settings-updater'] = true,
  ['nvim-claude.statusline'] = true,
  ['nvim-claude.agent_provider'] = true,
  ['nvim-claude.background_agent'] = true,
  ['nvim-claude.checkpoint'] = true,
  ['nvim-claude.events'] = true,
  ['nvim-claude.inline_diff'] = true,
  ['nvim-claude.lsp_mcp'] = true,
  ['nvim-claude.review_state'] = true,
  ['nvim-claude.rpc'] = true,
  ['nvim-claude.utils'] = true,

  -- Explicit secondary entrypoints used by composition or external adapters.
  ['nvim-claude.agent_provider.providers.codex.relay'] = true,
  ['nvim-claude.background_agent.commands'] = true,
  ['nvim-claude.chat.commands'] = true,
  ['nvim-claude.checkpoint.commands'] = true,
  ['nvim-claude.cursor_cpp.cmp_source'] = true,
  ['nvim-claude.debug.commands'] = true,
  ['nvim-claude.events.adapter'] = true,
  ['nvim-claude.lsp_mcp.bridge'] = true,
  ['nvim-claude.lsp_mcp.commands'] = true,
  ['nvim-claude.rpc.commands'] = true,
}

local edge_exceptions = {
  ['agent_provider -> nvim-claude.events.adapter'] =
    'OpenCode generates an external plugin that calls the public events RPC adapter',
}

local function source_package(path)
  local relative = path:sub(#root + 2)
  local rest = relative:match('^lua/nvim%-claude/(.+)$')
  if not rest then return nil end
  local first = rest:match('^([^/]+)')
  if first:match('%.lua$') then return top_level_packages[first] end
  if first == 'commands' then return 'app' end
  return first
end

local function target_package(module)
  if module == 'nvim-claude' then return 'app' end
  local rest = module:match('^nvim%-claude%.(.+)$')
  if not rest then return nil end
  local first = rest:match('^([^.]+)')
  if first == 'commands' or first == 'mappings' or first == 'settings-updater' or first == 'statusline' then
    return 'app'
  end
  if first == 'logger' or first == 'project-state' or first == 'project_state_schema' then return 'core' end
  return first
end

local function line_number_at(content, position)
  local _, count = content:sub(1, position):gsub('\n', '\n')
  return count + 1
end

local function extract_requires_from_content(content)
  local requires = {}
  local seen = {}
  local patterns = {
    [=[require%s*%(%s*['"]([^'"]+)['"]]=],
    [=[require%s+['"]([^'"]+)['"]]=],
    [=[pcall%s*%(%s*require%s*,%s*['"]([^'"]+)['"]]=],
  }

  for _, pattern in ipairs(patterns) do
    local offset = 1
    while true do
      local start_pos, end_pos, module = content:find(pattern, offset)
      if not start_pos then break end
      local key = start_pos .. ':' .. module
      if not seen[key] then
        seen[key] = true
        table.insert(requires, {
          module = module,
          line = line_number_at(content, start_pos),
        })
      end
      offset = end_pos + 1
    end
  end

  local dynamic = {}
  local dynamic_patterns = {
    [=[require%s*%(%s*([%a_][%w_.]*)]=],
    [=[require%s+([%a_][%w_.]*)]=],
    [=[pcall%s*%(%s*require%s*,%s*([%a_][%w_.]*)]=],
  }
  for _, pattern in ipairs(dynamic_patterns) do
    local offset = 1
    while true do
      local start_pos, end_pos, expression = content:find(pattern, offset)
      if not start_pos then break end
      table.insert(dynamic, {
        expression = expression,
        line = line_number_at(content, start_pos),
      })
      offset = end_pos + 1
    end
  end

  return requires, dynamic
end

local function extract_requires(path)
  local file = assert(io.open(path, 'r'))
  local content = file:read('*a')
  file:close()
  return extract_requires_from_content(content)
end

local files = vim.fn.glob(root .. '/lua/nvim-claude/**/*.lua', false, true)
table.sort(files)
local errors = {}
local graph = {}

for module in pairs(public_modules) do
  local module_path = root .. '/lua/' .. module:gsub('%.', '/')
  local exists = vim.fn.filereadable(module_path .. '.lua') == 1
    or vim.fn.filereadable(module_path .. '/init.lua') == 1
  if not exists then table.insert(errors, 'declared public module does not exist: ' .. module) end
end

local parser_probe = extract_requires_from_content([[
local private = require(
  'nvim-claude.inline_diff.private'
)
]])
assert(parser_probe[1] and parser_probe[1].module == 'nvim-claude.inline_diff.private')

for _, path in ipairs(files) do
  local from = source_package(path)
  local relative = path:sub(#root + 2)
  if not from or not packages[from] then
    table.insert(errors, relative .. ': unregistered source package ' .. tostring(from))
  else
    graph[from] = graph[from] or {}
    local requires, dynamic_requires = extract_requires(path)
    for _, item in ipairs(dynamic_requires) do
      table.insert(errors, string.format(
        '%s:%d: dynamic require cannot be checked (%s)',
        relative,
        item.line,
        item.expression
      ))
    end
    for _, item in ipairs(requires) do
      local to = target_package(item.module)
      if to then
        local location = string.format('%s:%d', relative, item.line)
        if not packages[to] then
          table.insert(errors, location .. ': import targets unregistered package ' .. to)
        elseif from ~= to then
          local exception_key = from .. ' -> ' .. item.module
          if not edge_exceptions[exception_key] then
            local allowed = packages[from].allow == '*' or packages[from].allow[to]
            if not allowed then
              table.insert(errors, string.format('%s: %s may not depend on %s (%s)', location, from, to, item.module))
            end
            if not public_modules[item.module] and not item.module:match('%.contract$') then
              table.insert(errors, location .. ': cross-package import targets private module ' .. item.module)
            end
            graph[from][to] = true
          end
        end
      end
    end
  end
end

local visiting = {}
local visited = {}
local stack = {}

local function visit(package_name)
  if visiting[package_name] then
    local cycle = {}
    local include = false
    for _, name in ipairs(stack) do
      if name == package_name then include = true end
      if include then table.insert(cycle, name) end
    end
    table.insert(cycle, package_name)
    table.insert(errors, 'package dependency cycle: ' .. table.concat(cycle, ' -> '))
    return
  end
  if visited[package_name] then return end

  visiting[package_name] = true
  table.insert(stack, package_name)
  for dependency in pairs(graph[package_name] or {}) do visit(dependency) end
  table.remove(stack)
  visiting[package_name] = nil
  visited[package_name] = true
end

for package_name in pairs(packages) do visit(package_name) end

if #errors > 0 then
  io.stderr:write('Dependency direction check failed:\n\n')
  for _, message in ipairs(errors) do io.stderr:write('  - ' .. message .. '\n') end
  vim.cmd 'cquit 1'
end

print(string.format('Dependency direction check passed (%d Lua files, %d packages)', #files, vim.tbl_count(packages)))
