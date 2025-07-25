-- Simple file-based logger for nvim-claude debugging
local M = {}

local utils = require('nvim-claude.utils')

-- Get log file path (in project's .nvim-claude directory)
function M.get_log_file()
  local project_root = utils.get_project_root()
  if project_root then
    -- Project-specific log
    return project_root .. '/.nvim-claude/debug.log'
  else
    -- Fallback to home directory
    return vim.fn.expand('~/.local/share/nvim/nvim-claude-debug.log')
  end
end

-- Write log entry
function M.log(level, component, message, data)
  local log_file = M.get_log_file()
  local log_dir = vim.fn.fnamemodify(log_file, ':h')
  
  -- Ensure directory exists
  if vim.fn.isdirectory(log_dir) == 0 then
    vim.fn.mkdir(log_dir, 'p')
  end
  
  -- Format log entry
  local timestamp = os.date('%Y-%m-%d %H:%M:%S')
  local entry = string.format('[%s] [%s] [%s] %s', timestamp, level, component, message)
  
  -- Add data if provided
  if data then
    entry = entry .. '\n  Data: ' .. vim.inspect(data)
  end
  
  entry = entry .. '\n'
  
  -- Append to log file
  local file = io.open(log_file, 'a')
  if file then
    file:write(entry)
    file:close()
  end
end

-- Convenience methods
function M.debug(component, message, data)
  M.log('DEBUG', component, message, data)
end

function M.info(component, message, data)
  M.log('INFO', component, message, data)
end

function M.warn(component, message, data)
  M.log('WARN', component, message, data)
end

function M.error(component, message, data)
  M.log('ERROR', component, message, data)
end

-- Clear log file
function M.clear()
  local log_file = M.get_log_file()
  local file = io.open(log_file, 'w')
  if file then
    file:close()
  end
end

-- Get log file size
function M.get_size()
  local log_file = M.get_log_file()
  local size = vim.fn.getfsize(log_file)
  return size > 0 and size or 0
end

-- Rotate log if too large (> 10MB)
function M.rotate_if_needed()
  local max_size = 10 * 1024 * 1024 -- 10MB
  if M.get_size() > max_size then
    local log_file = M.get_log_file()
    local backup_file = log_file .. '.old'
    os.rename(log_file, backup_file)
    M.info('logger', 'Log rotated (was ' .. M.get_size() .. ' bytes)')
  end
end

return M