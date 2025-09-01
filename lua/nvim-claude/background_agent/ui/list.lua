-- Minimal agent list UI: Enter switches tmux to the agent's window

local M = {}

local registry = require('nvim-claude.background_agent.registry')
local ba_diff = require('nvim-claude.background_agent.diff')
local tmux = require('nvim-claude.tmux')

local function fetch_active_agents()
  registry.validate_agents()
  local agents = registry.get_project_agents()
  local active = {}
  for _, a in ipairs(agents) do
    if a.status == 'active' then table.insert(active, a) end
  end
  table.sort(active, function(a, b) return (a.start_time or 0) > (b.start_time or 0) end)
  return active
end

function M.show()
  local agents = fetch_active_agents()
  if #agents == 0 then
    vim.notify('No active Claude agents', vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  local header = ' Claude Agents — <Enter>: switch · d: diff · k: kill · q: close '
  local lines = { header, '' }
  local line_to_idx = {}
  for i, agent in ipairs(agents) do
    local formatted = registry.format_agent(agent)
    table.insert(lines, formatted)
    line_to_idx[#lines] = i
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  local width = math.max(60, math.min(100, vim.o.columns - 10))
  local height = math.min(#lines + 2, vim.o.lines - 10)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Agent Selection ',
    title_pos = 'center',
  })
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:TelescopeNormal,FloatBorder:TelescopeBorder,FloatTitle:TelescopeTitle')
  vim.api.nvim_win_set_option(win, 'cursorline', true)

  local function close()
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local function current_agent()
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local idx = line_to_idx[lnum]
    return idx and agents[idx] or nil
  end

  -- Enter: switch to tmux window
  vim.keymap.set('n', '<CR>', function()
    local agent = current_agent()
    if not agent then return end
    if not tmux.is_inside_tmux() then
      vim.notify('Not inside tmux; cannot switch windows', vim.log.levels.ERROR)
      return
    end
    if agent.window_id then
      tmux.switch_to_window(agent.window_id)
      close()
    else
      vim.notify('Agent has no tmux window id', vim.log.levels.WARN)
    end
  end, { buffer = buf, silent = true })

  -- d: open diff in main Neovim
  vim.keymap.set('n', 'd', function()
    local agent = current_agent()
    if agent then ba_diff.open(agent) end
  end, { buffer = buf, silent = true })

  -- k: open kill selection UI
  vim.keymap.set('n', 'k', function()
    require('nvim-claude.background_agent').show_kill_ui()
    close()
  end, { buffer = buf, silent = true })

  -- q / Esc: close
  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true })
end

return M
