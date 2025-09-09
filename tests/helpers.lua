local M = {}

-- Redirect logger and project-state to safe temp locations for tests
do
  local logger = require('nvim-claude.logger')
  logger.get_log_file = function()
    local dir = '/tmp/nvim-claude-test-logs'
    vim.fn.mkdir(dir, 'p')
    return dir .. '/debug.log'
  end
  if logger.get_mcp_debug_log_file then
    logger.get_mcp_debug_log_file = function()
      return '/tmp/nvim-claude-mcp-debug.log'
    end
  end
  if logger.get_stop_hook_log_file then
    logger.get_stop_hook_log_file = function()
      return '/tmp/stop-hook-debug.log'
    end
  end
end

do
  local project_state = require('nvim-claude.project-state')
  local state_dir = '/tmp/nvim-claude-test-state'
  vim.fn.mkdir(state_dir, 'p')
  local state_file = state_dir .. '/state.json'
  project_state.get_state_file = function() return state_file end
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.delete(dir, 'rf')
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function git(cmd, cwd)
  cwd = cwd or vim.loop.cwd()
  local full = string.format("cd '%s' && %s 2>&1", cwd, cmd)
  return vim.fn.system(full)
end

local function init_repo(root)
  git('git init -q', root)
  git('git config user.email test@example.com', root)
  git('git config user.name test', root)
end

local function write_lines(path, lines)
  vim.fn.writefile(lines, path)
end

local function read_file(path)
  if vim.fn.filereadable(path) == 0 then return nil end
  local lines = vim.fn.readfile(path)
  return table.concat(lines, '\n')
end

local function open_buf(path)
  vim.cmd('edit ' .. path)
  return vim.fn.bufnr(path)
end

M.tmpdir = tmpdir
M.git = git
M.init_repo = init_repo
M.write_lines = write_lines
M.read_file = read_file
M.open_buf = open_buf

return M

