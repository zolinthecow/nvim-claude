-- Tmux interaction module (utils namespace)
local M = {}
local utils = require('nvim-claude.utils.core')

M.config = {}

function M.setup(config)
  M.config = config or {}
  -- Defaults for generic chat pane detection
  if M.config.pane_title == nil then M.config.pane_title = 'claude-chat' end
  if M.config.process_pattern == nil then M.config.process_pattern = '(claude|claude-code)' end
end

-- Find chat pane by tmux title or process pattern
function M.find_chat_pane()
  local cmd = "tmux list-panes -F '#{pane_id}:#{pane_pid}:#{pane_title}:#{pane_current_command}'"
  local result = utils.exec(cmd)
  if result and result ~= '' then
    for line in result:gmatch('[^\n]+') do
      local pane_id, pane_pid, pane_title, pane_cmd = line:match('^([^:]+):([^:]+):([^:]*):(.*)$')
      if pane_id and pane_pid then
        if pane_title and pane_title == (M.config.pane_title or 'claude-chat') then return pane_id end
        local pattern = M.config.process_pattern or '(claude|claude-code)'
        if pane_cmd and pane_cmd:match(pattern) then return pane_id end
        local check_cmd = string.format("ps -ef | awk '$3 == %s' | grep -c -E %q 2>/dev/null", pane_pid, pattern)
        local count_result = utils.exec(check_cmd)
        if count_result and tonumber(count_result) and tonumber(count_result) > 0 then return pane_id end
      end
    end
  end
  return nil
end

-- Legacy alias (backward compatibility)
function M.find_claude_pane()
  return M.find_chat_pane()
end

-- Create new tmux pane for Claude (or return existing)
function M.create_pane(command)
  local existing = M.find_chat_pane()
  if existing then
    local _, err = utils.exec('tmux select-pane -t ' .. existing)
    if err then
      vim.notify('Chat pane no longer exists, creating new one', vim.log.levels.INFO)
    else
      return existing
    end
  end

  local size_opt = ''
  if M.config.split_size and tonumber(M.config.split_size) then
    local size = tonumber(M.config.split_size)
    if utils.tmux_supports_length_percent() then size_opt = '-l ' .. tostring(size) .. '%'
    else size_opt = '-p ' .. tostring(size) end
  end

  local split_cmd = M.config.split_direction == 'v' and 'split-window -v' or 'split-window -h'
  local parts = { 'tmux', split_cmd }
  if size_opt ~= '' then table.insert(parts, size_opt) end
  table.insert(parts, '-P')
  local cmd = table.concat(parts, ' ')

  local result, err = utils.exec(cmd)
  if err or not result or result == '' or result:match('error') then
    vim.notify('nvim-claude: tmux split failed: ' .. (err or result or 'unknown'), vim.log.levels.ERROR)
    return nil
  end

  local pane_id = result:gsub('\n', '')
  utils.exec(string.format("tmux select-pane -t %s -T '%s'", pane_id, M.config.pane_title or 'claude-chat'))
  if command and command ~= '' then
    if command == 'claude' then
      vim.defer_fn(function() M.send_to_pane(pane_id, command) end, 1000)
    else
      M.send_to_pane(pane_id, command)
    end
  end
  return pane_id
end

-- Send keys to a pane (single line with Enter)
function M.send_to_pane(pane_id, text)
  if not pane_id then return false end
  text = text:gsub("'", "'\"'\"'")
  local cmd = string.format("tmux send-keys -t %s '%s' Enter", pane_id, text)
  local _, err = utils.exec(cmd)
  return err == nil
end

-- Send multi-line text to a pane (for batched content)
function M.send_text_to_pane(pane_id, text)
  if not pane_id then return false end
  local tmpfile = os.tmpname()
  local file = io.open(tmpfile, 'w')
  if not file then
    vim.notify('Failed to create temporary file for text', vim.log.levels.ERROR)
    return false
  end
  file:write(text)
  file:close()
  local cmd = string.format("tmux load-buffer -t %s '%s' && tmux paste-buffer -t %s && rm '%s'", pane_id, tmpfile, pane_id, tmpfile)
  local _, err = utils.exec(cmd)
  if err then
    os.remove(tmpfile)
    vim.notify('Failed to send text to pane: ' .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

-- Create new tmux window for agent
function M.create_agent_window(name, cwd)
  local base_cmd = string.format("tmux new-window -n '%s'", name)
  if cwd and cwd ~= '' then base_cmd = base_cmd .. string.format(" -c '%s'", cwd) end
  local cmd_with_fmt = base_cmd .. " -P -F '#{window_id}'"
  local result, err = utils.exec(cmd_with_fmt)
  if not err and result and result ~= '' and not result:match('error') then return result:gsub('\n', '') end
  local cmd_simple = base_cmd .. ' -P'
  result, err = utils.exec(cmd_simple)
  if not err and result and result ~= '' then return result:gsub('\n', '') end
  vim.notify('nvim-claude: tmux new-window failed: ' .. (err or result or 'unknown'), vim.log.levels.ERROR)
  return nil
end

function M.send_to_window(window_id, text)
  if not window_id then return false end
  text = text:gsub("'", "'\"'\"'")
  local cmd = string.format("tmux send-keys -t %s '%s' Enter", window_id, text)
  local _, err = utils.exec(cmd)
  return err == nil
end

function M.switch_to_window(window_id)
  local cmd = 'tmux select-window -t ' .. window_id
  local _, err = utils.exec(cmd)
  return err == nil
end

function M.kill_pane(pane_id)
  local cmd = 'tmux kill-pane -t ' .. pane_id
  local _, err = utils.exec(cmd)
  return err == nil
end

function M.is_inside_tmux()
  if os.getenv('TMUX') then return true end
  local result = utils.exec('tmux display-message -p "#{session_name}" 2>/dev/null')
  return result and result ~= '' and not result:match('error')
end

function M.validate()
  if not utils.has_tmux() then
    vim.notify('tmux not found. Please install tmux.', vim.log.levels.ERROR)
    return false
  end
  if not M.is_inside_tmux() then
    vim.notify('Not inside tmux session. Please run nvim inside tmux.', vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.split_window(window_id, direction, size_percent)
  direction = direction == 'v' and '-v' or '-h'
  local size_opt = ''
  if size_percent and tonumber(size_percent) then
    local size = tonumber(size_percent)
    if utils.tmux_supports_length_percent() then size_opt = string.format('-l %s%%', size)
    else size_opt = string.format('-p %s', size) end
  end
  local parts = { 'tmux', 'split-window', direction }
  if size_opt ~= '' then table.insert(parts, size_opt) end
  table.insert(parts, '-P -F "#{pane_id}"')
  table.insert(parts, '-t ' .. window_id)
  local cmd = table.concat(parts, ' ')
  local pane_id, err = utils.exec(cmd)
  if err or not pane_id or pane_id == '' then
    vim.notify('nvim-claude: tmux split-window failed: ' .. (err or pane_id or 'unknown'), vim.log.levels.ERROR)
    return nil
  end
  return pane_id:gsub('\n', '')
end

return M
