-- Agent creation UI (temporary adapter): delegates to existing commands UI

local M = {}

local ba = require('nvim-claude.background_agent')
local utils = require('nvim-claude.utils')
local git = require('nvim-claude.git')

-- Internal: branch selection picker
local function show_branch_selection(callback)
  local branches_output = utils.exec 'git branch -a'
  if not branches_output then
    vim.notify('Failed to get branches', vim.log.levels.ERROR)
    callback(nil)
    return
  end
  local branches = {}
  for line in branches_output:gmatch '[^\n]+' do
    local branch = line:match '^%s*%*?%s*(.+)$'
    if branch and not branch:match 'HEAD detached' then
      branch = branch:gsub('^remotes/origin/', '')
      table.insert(branches, branch)
    end
  end
  local seen, unique = {}, {}
  for _, b in ipairs(branches) do if not seen[b] then seen[b] = true; table.insert(unique, b) end end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  local state = { selected = 1 }

  local function update_display()
    local lines = { 'Select branch to fork from:', '' }
    for i, b in ipairs(unique) do
      local icon = i == state.selected and '▶' or ' '
      table.insert(lines, string.format('%s %s', icon, b))
    end
    table.insert(lines, '')
    table.insert(lines, 'Press <Tab> to select, <Esc> to cancel')
    table.insert(lines, 'Use j/k or arrow keys to navigate')
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  end
  update_display()

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#unique + 6, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    col = math.floor((vim.o.columns - width) / 2), row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal', border = 'rounded', title = ' Branch Selection ', title_pos = 'center',
  })
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')
  vim.cmd 'stopinsert'

  local function move(delta) state.selected = math.max(1, math.min(#unique, state.selected + delta)); update_display() end
  local function select() local b = unique[state.selected]; if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end; callback(b) end
  local function close() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end; callback(nil) end

  vim.keymap.set('n', 'j', function() move(1) end, { buffer = buf, silent = true })
  vim.keymap.set('n', 'k', function() move(-1) end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Down>', function() move(1) end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Up>', function() move(-1) end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Tab>', select, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', select, { buffer = buf, silent = true })
  for i = 1, math.min(9, #unique) do
    vim.keymap.set('n', tostring(i), function() state.selected = i; update_display(); select() end, { buffer = buf, silent = true })
  end
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true })
end

-- Setup detection/history helpers
local function detect_setup_commands(project_root)
  local cmds = {}
  if utils.file_exists(project_root .. '/.env') then
    table.insert(cmds, '# Copy environment config from main project')
    table.insert(cmds, 'cp ../../.env .')
  end
  if utils.file_exists(project_root .. '/.env.local') then table.insert(cmds, 'cp ../../.env.local .') end
  if utils.file_exists(project_root .. '/pnpm-lock.yaml') then
    table.insert(cmds, ''); table.insert(cmds, '# Install dependencies'); table.insert(cmds, 'pnpm install')
  elseif utils.file_exists(project_root .. '/yarn.lock') then
    table.insert(cmds, ''); table.insert(cmds, '# Install dependencies'); table.insert(cmds, 'yarn install')
  elseif utils.file_exists(project_root .. '/package-lock.json') or utils.file_exists(project_root .. '/package.json') then
    table.insert(cmds, ''); table.insert(cmds, '# Install dependencies'); table.insert(cmds, 'npm install')
  end
  if utils.file_exists(project_root .. '/requirements.txt') then
    table.insert(cmds, ''); table.insert(cmds, '# Install Python dependencies'); table.insert(cmds, 'pip install -r requirements.txt')
  elseif utils.file_exists(project_root .. '/pyproject.toml') then
    table.insert(cmds, ''); table.insert(cmds, '# Install Python project'); table.insert(cmds, 'pip install -e .')
  end
  if utils.file_exists(project_root .. '/package.json') then
    local content = table.concat(vim.fn.readfile(project_root .. '/package.json'), '\n')
    if content:match '"build"' then
      table.insert(cmds, ''); table.insert(cmds, '# Build the project')
      local pm = utils.file_exists(project_root .. '/pnpm-lock.yaml') and 'pnpm' or (utils.file_exists(project_root .. '/yarn.lock') and 'yarn' or 'npm')
      table.insert(cmds, pm .. ' run build')
    end
  end
  if utils.file_exists(project_root .. '/Makefile') then
    local content = table.concat(vim.fn.readfile(project_root .. '/Makefile'), '\n')
    if content:match '^setup:' then
      table.insert(cmds, ''); table.insert(cmds, '# Run Makefile setup'); table.insert(cmds, 'make setup')
    end
  end
  return cmds
end

local function load_setup_history(project_root)
  local project_state = require('nvim-claude.project-state')
  return project_state.get(project_root, 'agent_setup_history')
end

local function save_setup_history(project_root, cmds)
  local project_state = require('nvim-claude.project-state')
  project_state.set(project_root, 'agent_setup_history', { last_used = os.date '!%Y-%m-%dT%H:%M:%SZ', setup_commands = cmds })
end

-- UI step 3: setup commands
local function show_setup_instructions_ui(state)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'bash')

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(25, vim.o.lines - 6)
  local divider = string.rep('━', width)

  local project_root = utils.get_project_root()
  local commands = state.setup_commands
  if not commands then
    local history = load_setup_history(project_root)
    commands = (history and history.setup_commands) or detect_setup_commands(project_root)
  end

  local lines = { divider, ' Agent Setup Instructions', divider, '', 'The agent will need to set up the worktree environment.', 'Edit the commands below as needed:', '' }
  for _, cmd in ipairs(commands) do table.insert(lines, cmd) end
  table.insert(lines, ''); table.insert(lines, '# Additional setup'); table.insert(lines, '# (add any other setup commands here)'); table.insert(lines, '');
  table.insert(lines, divider); table.insert(lines, 'Press <Tab> to start agent · <S-Tab> to go back · <Esc> to cancel'); table.insert(lines, divider)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height, col = math.floor((vim.o.columns - width)/2), row = math.floor((vim.o.lines - height)/2), style = 'minimal', border = 'rounded', title = ' Setup Instructions (Step 3/3) ', title_pos = 'center' })
  vim.api.nvim_win_set_cursor(win, { 8, 0 })

  local function extract_commands()
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local out, in_cmds = {}, false
    for _, line in ipairs(all) do
      if line:match '^━+$' then if in_cmds then break end
      elseif line:match 'Agent Setup Instructions' then in_cmds = true
      elseif in_cmds and line ~= '' and not line:match '^The agent will' and not line:match '^Edit the commands' then table.insert(out, line) end
    end
    return out
  end

  local function continue()
    state.setup_commands = extract_commands()
    vim.api.nvim_win_close(win, true)
    save_setup_history(project_root, state.setup_commands)
    ba.create_agent(state.mission, state.fork_from, state.setup_commands)
  end
  local function cancel() vim.api.nvim_win_close(win, true) end
  local function go_back() vim.api.nvim_win_close(win, true); show_fork_options_ui(state) end

  vim.keymap.set('n', '<Tab>', continue, { buffer = buf, silent = true })
  vim.keymap.set('i', '<Tab>', continue, { buffer = buf, silent = true })
  vim.keymap.set('n', '<S-Tab>', go_back, { buffer = buf, silent = true })
  vim.keymap.set('i', '<S-Tab>', go_back, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = buf, silent = true })
end

-- UI step 2: fork options
function show_fork_options_ui(state)
  vim.cmd 'stopinsert'
  local default_branch = git.default_branch()
  local options = {
    { label = 'Current branch', desc = 'Fork from your current branch state', value = 1 },
    { label = default_branch .. ' branch', desc = 'Start fresh from ' .. default_branch .. ' branch', value = 2 },
    { label = 'Stash current changes', desc = 'Include your uncommitted changes', value = 3 },
    { label = 'Other branch...', desc = 'Choose any branch to fork from', value = 4 },
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  local lines = {}
  local mission_first_line = state.mission:match '[^\n]*' or state.mission
  local mission_preview = mission_first_line:sub(1, 60) .. (mission_first_line:len() > 60 and '...' or '')
  table.insert(lines, string.format('Mission: %s', mission_preview))
  table.insert(lines, '')
  table.insert(lines, 'Select fork option:')
  table.insert(lines, '')
  for i, opt in ipairs(options) do
    local icon = i == state.fork_option and '▶' or ' '
    table.insert(lines, string.format('%s %d. %s', icon, i, opt.label))
    table.insert(lines, string.format('   %s', opt.desc))
    table.insert(lines, '')
  end
  table.insert(lines, 'Press <Tab> to configure setup instructions, <S-Tab> to go back, q to cancel')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 4, vim.o.lines - 10)
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height, col = math.floor((vim.o.columns - width)/2), row = math.floor((vim.o.lines - height)/2), style = 'minimal', border = 'rounded', title = ' Fork Options (Step 2/3) ', title_pos = 'center' })
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')

  local function update_display()
    local updated = {}
    local mission_first_line = state.mission:match '[^\n]*' or state.mission
    local mission_preview = mission_first_line:sub(1, 60) .. (mission_first_line:len() > 60 and '...' or '')
    table.insert(updated, string.format('Mission: %s', mission_preview))
    table.insert(updated, '')
    table.insert(updated, 'Select fork option:')
    table.insert(updated, '')
    for i, opt in ipairs(options) do
      local icon = i == state.fork_option and '▶' or ' '
      table.insert(updated, string.format('%s %d. %s', icon, i, opt.label))
      table.insert(updated, string.format('   %s', opt.desc))
      table.insert(updated, '')
    end
    table.insert(updated, 'Press <Tab> to configure setup instructions, q to cancel')
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, updated)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  end

  local function create_agent()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    local fork_from
    local def = git.default_branch()
    if state.fork_option == 1 then
      fork_from = { type = 'branch', branch = git.current_branch() or def }
    elseif state.fork_option == 2 then
      fork_from = { type = 'branch', branch = def }
    elseif state.fork_option == 3 then
      fork_from = { type = 'stash' }
    elseif state.fork_option == 4 then
      vim.cmd 'stopinsert'
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      vim.schedule(function()
        show_branch_selection(function(branch)
          if branch then
            fork_from = { type = 'branch', branch = branch }
            state.fork_from = fork_from
            show_setup_instructions_ui(state)
          end
        end)
      end)
      return
    end
    state.fork_from = fork_from
    show_setup_instructions_ui(state)
  end

  local function move_up() if state.fork_option > 1 then state.fork_option = state.fork_option - 1; update_display() end end
  local function move_down() if state.fork_option < #options then state.fork_option = state.fork_option + 1; update_display() end end
  local function close_window() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
  local function go_back() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end; M.start() end

  for i = 1, #options do vim.keymap.set('n', tostring(i), function() state.fork_option = i; update_display() end, { buffer = buf, silent = true }) end
  vim.keymap.set('n', 'j', move_down, { buffer = buf, silent = true })
  vim.keymap.set('n', 'k', move_up, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Down>', move_down, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Up>', move_up, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Tab>', create_agent, { buffer = buf, silent = true })
  vim.keymap.set('n', '<S-Tab>', go_back, { buffer = buf, silent = true })
  vim.keymap.set('n', 'q', close_window, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', close_window, { buffer = buf, silent = true })
end

-- UI step 1: mission input
local function show_mission_input_ui()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')

  local lines = {
    '# Agent Mission Description', '',
    'Enter your detailed mission description below.',
    'You can use multiple lines and markdown formatting.', '',
    '## Task:', '', '(Type your task here...)', '',
    '## Goals:', '- ', '', '## Notes:', '- ', '', '',
    '────────────────────────────────────────',
    'Press <Tab> to continue to fork options',
    'Press <Esc> to cancel',
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(25, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height, col = math.floor((vim.o.columns - width)/2), row = math.floor((vim.o.lines - height)/2), style = 'minimal', border = 'rounded', title = ' Agent Mission (Step 1/3) ', title_pos = 'center' })
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')
  vim.api.nvim_win_set_cursor(win, { 8, 0 })

  local function get_mission()
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local mission_lines, in_content = {}, false
    for _, line in ipairs(all_lines) do
      if line:match '^────' then break end
      if line:match '^# Agent Mission' or line:match '^Enter your detailed' or line:match '^You can use multiple' then
        -- skip
      else
        if line ~= '' or in_content then in_content = true; table.insert(mission_lines, line) end
      end
    end
    local mission = table.concat(mission_lines, '\n'):gsub('^%s*(.-)%s*$', '%1')
    mission = mission:gsub('%(Type your task here%.%.%.%)', '')
    return mission
  end

  local function proceed()
    local mission = get_mission()
    if mission == '' or mission:match '^%s*$' then
      vim.notify('Please enter a mission description', vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    show_fork_options_ui({ fork_option = 1, mission = mission })
  end
  local function close_window() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end

  vim.keymap.set('n', '<Tab>', proceed, { buffer = buf, silent = true })
  vim.keymap.set('i', '<Tab>', proceed, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', close_window, { buffer = buf, silent = true })
  vim.cmd 'startinsert'
end

function M.start()
  show_mission_input_ui()
  return true
end

return M
