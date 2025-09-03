-- Simple file-based logger for nvim-claude debugging
local M = {}

local utils = require 'nvim-claude.utils'
local function project_log_dir()
  local project_root = utils.get_project_root()
  if not project_root then
    return nil
  end
  local project_state = require 'nvim-claude.project-state'
  local project_key = project_state.get_project_key(project_root)
  local key_hash = vim.fn.sha256(project_key)
  local short_hash = key_hash:sub(1, 8)
  local dir = vim.fn.stdpath 'data' .. '/nvim-claude/logs/' .. short_hash
  utils.ensure_dir(dir)
  return dir
end

-- Get log file path (in global storage)
function M.get_log_file()
  local dir = project_log_dir()
  if dir then
    return dir .. '/debug.log'
  end
  return vim.fn.expand '~/.local/share/nvim/nvim-claude-debug.log'
end

-- Get stop-hook debug log file path for bash scripts
function M.get_stop_hook_log_file()
  local dir = project_log_dir()
  if dir then return dir .. '/debug.log' end
  return vim.fn.expand '~/.local/share/nvim/nvim-claude-debug.log'
end

-- Get MCP debug log file path
function M.get_mcp_debug_log_file()
  local dir = project_log_dir()
  if dir then
    return dir .. '/mcp-debug.log'
  end
  return '/tmp/nvim-claude-mcp-debug.log'
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
  local timestamp = os.date '%Y-%m-%d %H:%M:%S'
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
  local current_size = M.get_size()
  if current_size > max_size then
    local log_file = M.get_log_file()
    local backup_file = log_file .. '.old'
    os.rename(log_file, backup_file)
    M.info('logger', 'Log rotated (was ' .. current_size .. ' bytes)')
  end
end

return M
