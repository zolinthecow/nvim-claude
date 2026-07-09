-- Utility functions for nvim-claude
local M = {}

local project_root_cache = {}

local function normalize_dir(path)
  if not path or path == '' then return nil end
  local resolved = vim.fn.resolve(vim.fn.fnamemodify(path, ':p'))
  local normalized = (resolved or ''):gsub('/+$', '')
  if normalized == '' and resolved == '/' then return '/' end
  return normalized
end

local function git_root_for_dir(dir)
  dir = normalize_dir(dir)
  if not dir or dir == '' then return nil end

  local cached = project_root_cache[dir]
  if cached then return cached end

  local lookup_dir = dir
  while lookup_dir and vim.fn.isdirectory(lookup_dir) == 0 do
    local parent = normalize_dir(vim.fn.fnamemodify(lookup_dir, ':h'))
    if not parent or parent == lookup_dir then return nil end
    lookup_dir = parent
  end
  if not lookup_dir then return nil end

  local output = vim.fn.system({ 'git', '-C', lookup_dir, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 or not output or output == '' then
    return nil
  end

  local root = normalize_dir(output:gsub('%s+$', ''))
  project_root_cache[dir] = root
  project_root_cache[lookup_dir] = root
  if root then project_root_cache[root] = root end
  return root
end

-- Check if we're in a git repository
function M.is_git_repo()
  return git_root_for_dir(vim.fn.getcwd()) ~= nil
end

-- Get project root (git root or current working directory)
function M.get_project_root()
  local cwd = normalize_dir(vim.fn.getcwd())
  return git_root_for_dir(cwd) or cwd
end

-- Get project root for a specific file path
function M.get_project_root_for_file(file_path)
  if not file_path then
    return M.get_project_root()
  end

  -- Determine working directory: if given path is a directory, use it directly;
  -- otherwise use the file's parent directory. This prevents ascending one level
  -- when callers intentionally pass a project directory (e.g., stop hook clear).
  local stat = vim.loop.fs_stat(file_path)
  local file_dir
  if stat and stat.type == 'directory' then
    file_dir = file_path
  else
    file_dir = vim.fn.fnamemodify(file_path, ':h')
  end

  file_dir = normalize_dir(file_dir)
  return git_root_for_dir(file_dir) or file_dir
end

function M.clear_project_root_cache()
  project_root_cache = {}
end

-- Create directory if it doesn't exist
function M.ensure_dir(path)
  local stat = vim.loop.fs_stat(path)
  if not stat then
    vim.fn.mkdir(path, 'p')
    return true
  end
  return stat.type == 'directory'
end

-- Read file contents
function M.read_file(path)
  local file, err = io.open(path, 'r')
  if not file then
    return nil, err
  end
  local content = file:read '*a'
  file:close()
  return content
end

-- Write file contents
function M.write_file(path, content)
  local file = io.open(path, 'w')
  if not file then
    return false
  end
  file:write(content)
  file:close()
  return true
end

-- Check if file exists
function M.file_exists(path)
  local stat = vim.loop.fs_stat(path)
  return stat ~= nil
end

-- Generate timestamp string
function M.timestamp()
  return os.date '%Y-%m-%d-%H%M%S'
end

-- Generate agent directory name
function M.agent_dirname(task)
  -- Sanitize task name for filesystem
  local safe_task = task:gsub('[^%w%-_]', '-'):gsub('%-+', '-'):sub(1, 50)
  return string.format('agent-%s-%s', M.timestamp(), safe_task)
end

-- Execute shell command and return output
function M.exec(cmd)
  if type(cmd) ~= 'string' or cmd == '' then
    return nil, 'Failed to execute command'
  end

  -- Wrap in a subshell so we can always capture stderr without overriding
  -- redirections that may already exist inside `cmd`.
  local wrapped_cmd = '(' .. cmd .. ') 2>&1'
  local result = vim.fn.system(wrapped_cmd)
  local exit_code = vim.v.shell_error

  if exit_code == 0 then
    return result, nil
  else
    local err = (result and result ~= '') and result or ('Command failed with exit code ' .. tostring(exit_code))
    return nil, err
  end
end

-- Write content to a temp file, returning the path (caller must clean up)
function M.write_temp_file(content)
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, 'w')
  if not f then
    return nil
  end
  f:write(content or '')
  f:close()
  return tmpfile
end

-- Check if tmux is available
function M.has_tmux()
  local result = M.exec 'which tmux'
  return result and result:match '/tmux'
end

-- Get current tmux session
function M.get_tmux_session()
  local result = M.exec 'tmux display-message -p "#{session_name}" 2>/dev/null'
  if result and result ~= '' then
    return result:gsub('\n', '')
  end
  return nil
end

-- Get tmux version as number (e.g., 3.4) or 0 if unknown
function M.tmux_version()
  local result = M.exec 'tmux -V 2>/dev/null'
  if not result then
    return 0
  end
  -- Expected output: "tmux 3.4"
  local ver = result:match 'tmux%s+([0-9]+%.[0-9]+)'
  return tonumber(ver) or 0
end

-- Determine if tmux supports the new -l <percent>% syntax (>= 3.4)
function M.tmux_supports_length_percent()
  return M.tmux_version() >= 3.4
end

-- Write JSON to file
function M.write_json(path, data)
  local success, json = pcall(vim.fn.json_encode, data)
  if not success then
    return false, 'Failed to encode JSON: ' .. json
  end

  local file = io.open(path, 'w')
  if not file then
    return false, 'Failed to open file for writing: ' .. path
  end

  -- Pretty print JSON
  local formatted = json:gsub('},{', '},\n    {'):gsub('\\{', '{\n  '):gsub('\\}', '\n}')
  file:write(formatted)
  file:close()
  return true, nil
end

-- Read JSON from file
function M.read_json(path)
  local content = M.read_file(path)
  if not content then
    return nil, 'Failed to read file: ' .. path
  end

  local success, data = pcall(vim.fn.json_decode, content)
  if not success then
    return nil, 'Failed to decode JSON: ' .. data
  end

  return data, nil
end

return M
