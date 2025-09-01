-- Kill selection UI for background agents

local M = {}

local ba = require('nvim-claude.background_agent')

local function fetch_active_agents()
  ba.registry_validate()
  local agents = ba.registry_agents()
  local active = {}
  for _, a in ipairs(agents) do
    if a.status == 'active' then
      table.insert(active, a)
    end
  end
  table.sort(active, function(a, b) return (a.start_time or 0) > (b.start_time or 0) end)
  return active
end

function M.show()
  local agents = fetch_active_agents()
  if #agents == 0 then
    vim.notify('No active agents to kill', vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  local width = 80
  local height = math.min(#agents * 4 + 4, 25)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = width, height = height,
    col = (vim.o.columns - width) / 2, row = (vim.o.lines - height) / 2,
    style = 'minimal', border = 'rounded', title = ' Kill Claude Agents ', title_pos = 'center',
  })
  vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Normal,FloatBorder:Comment')

  local selected = {}
  for i = 1, #agents do selected[i] = false end

  local function render()
    local lines = { 'Kill Claude Agents (Space: toggle, Y: confirm kill, q: quit):', '' }
    for i, agent in ipairs(agents) do
      local icon = selected[i] and '●' or '○'
      table.insert(lines, string.format('%s %s', icon, ba.registry_format(agent)))
      table.insert(lines, '    ID: ' .. (agent.id or agent._registry_id or ''))
      table.insert(lines, '    Window: ' .. (agent.window_name or 'unknown'))
      table.insert(lines, '')
    end
    local cur = vim.api.nvim_win_get_cursor(win)[1]
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { math.min(cur, #lines), 0 })
    end
  end

  local function close() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
  local function line_to_index(line)
    if line <= 2 then return nil end
    local idx = math.ceil((line - 2) / 4)
    return idx <= #agents and idx or nil
  end
  local function toggle()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local idx = line_to_index(line)
    if idx then selected[idx] = not selected[idx]; render() end
  end
  local function confirm()
    local any = false
    for i, sel in ipairs(selected) do
      if sel then
        any = true
        ba.kill_agent(agents[i].id or agents[i]._registry_id)
      end
    end
    if not any then vim.notify('No agents selected', vim.log.levels.INFO); return end
    close()
  end

  render()
  vim.keymap.set('n', '<Space>', toggle, { buffer = buf, silent = true })
  vim.keymap.set('n', 'Y', confirm, { buffer = buf, silent = true })
  vim.keymap.set('n', 'y', confirm, { buffer = buf, silent = true })
  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true })
end

return M

