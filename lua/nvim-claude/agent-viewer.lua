-- Agent viewer module for nvim-claude
local M = {}
local utils = require 'nvim-claude.utils'

-- View agent's mission log
function M.view_mission_log(agent_dir)
  local mission_file = agent_dir .. '/mission.log'
  if not utils.file_exists(mission_file) then
    vim.notify('No mission log found for this agent', vim.log.levels.WARN)
    return
  end

  -- Open in a new split
  vim.cmd('split ' .. mission_file)
  vim.cmd 'setlocal readonly'
  vim.cmd 'setlocal nomodifiable'
end

-- View agent's progress
function M.view_progress(agent_dir)
  local progress_file = agent_dir .. '/progress.txt'
  if not utils.file_exists(progress_file) then
    vim.notify('No progress file found for this agent', vim.log.levels.INFO)
    return
  end

  local content = utils.read_file(progress_file)
  if not content or content == '' then
    content = 'No progress reported yet'
  end

  -- Show in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(content, '\n')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 2, 20)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Agent Progress ',
    title_pos = 'center',
  })

  -- Close on q or Esc
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>', { silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>', { silent = true })
end

-- Live tail agent's progress
function M.tail_progress(agent_dir)
  local progress_file = agent_dir .. '/progress.txt'

  -- Create a terminal buffer
  vim.cmd 'split'
  vim.cmd('terminal tail -f ' .. vim.fn.shellescape(progress_file))
  vim.cmd 'setlocal nonumber norelativenumber'
  vim.cmd 'startinsert'

  -- Set buffer name
  vim.api.nvim_buf_set_name(0, 'Agent Progress: ' .. vim.fn.fnamemodify(agent_dir, ':t'))
end

-- Quick status check for all agents
function M.show_agent_status()
  local registry = require 'nvim-claude.registry'
  local agents = registry.get_project_agents()

  if #agents == 0 then
    vim.notify('No active agents', vim.log.levels.INFO)
    return
  end

  local lines = { 'Agent Status Summary:', '' }

  for _, agent in ipairs(agents) do
    local status_line = string.format('[%s] %s', agent.status == 'active' and '●' or '○', agent.task:match '[^\n]*' or agent.task)
    table.insert(lines, status_line)

    -- Try to read progress
    local progress_file = agent.work_dir .. '/progress.txt'
    if utils.file_exists(progress_file) then
      local progress = utils.read_file(progress_file)
      if progress and progress ~= '' then
        -- Get last line of progress
        local last_line = progress:match '([^\n]*)$'
        if last_line and last_line ~= '' then
          table.insert(lines, '  → ' .. last_line)
        end
      end
    end

    table.insert(lines, '')
  end

  -- Show in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(#lines + 2, vim.o.lines - 10)

  vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Agent Status ',
    title_pos = 'center',
  })

  -- Keymaps
  vim.api.nvim_buf_set_keymap(buf, 'n', 'q', ':close<CR>', { silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', ':close<CR>', { silent = true })
  vim.api.nvim_buf_set_keymap(buf, 'n', 'r', '', {
    callback = function()
      vim.api.nvim_win_close(0, true)
      M.show_agent_status()
    end,
    silent = true,
    desc = 'Refresh status',
  })
end

return M

