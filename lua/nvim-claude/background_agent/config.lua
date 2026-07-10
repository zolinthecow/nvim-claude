local M = {}

local defaults = {
  work_dir = '.agent-work',
  auto_gitignore = true,
  max_agents = 5,
  cleanup_days = 7,
}

local current = vim.deepcopy(defaults)

function M.setup(config)
  current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), config or {})
  return vim.deepcopy(current)
end

function M.get()
  return vim.deepcopy(current)
end

return M
