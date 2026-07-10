local M = {}

local utils = require 'nvim-claude.utils.core'

M.config = {}

local function run(project_root, command)
  local prefix = ''
  if project_root and project_root ~= '' then
    prefix = 'cd ' .. vim.fn.shellescape(project_root) .. ' && '
  end
  return utils.exec(prefix .. command)
end

local function normalize_path(path)
  return vim.fn.resolve(vim.fn.fnamemodify(path, ':p')):gsub('/+$', '')
end

local function rev_parse(project_root, ref)
  local result, err = run(
    project_root,
    'git rev-parse --verify --quiet ' .. vim.fn.shellescape(ref)
  )
  if err or not result then return nil end
  result = vim.trim(result)
  return result ~= '' and result or nil
end

function M.setup(config)
  M.config = config or {}
end

function M.supports_worktrees(project_root)
  local result = run(project_root, 'git worktree list --porcelain')
  return result ~= nil
end

function M.list_worktrees(project_root)
  local result = run(project_root, 'git worktree list --porcelain')
  if not result then return {} end

  local worktrees = {}
  local current = {}
  for line in result:gmatch('[^\n]+') do
    if line:match('^worktree ') then
      if current.path then table.insert(worktrees, current) end
      current = { path = line:match('^worktree (.+)') }
    elseif line:match('^HEAD ') then
      current.head = line:match('^HEAD (.+)')
    elseif line:match('^branch ') then
      current.branch = line:match('^branch (.+)')
    end
  end
  if current.path then table.insert(worktrees, current) end
  return worktrees
end

function M.create_worktree(path, branch, project_root)
  project_root = project_root or utils.get_project_root()
  branch = branch or M.default_branch(project_root)
  if not project_root or not branch then
    return false, 'Could not resolve project root or base branch'
  end

  local normalized = normalize_path(path)
  for _, worktree in ipairs(M.list_worktrees(project_root)) do
    if normalize_path(worktree.path) == normalized then
      return false, 'Worktree already exists: ' .. path
    end
  end

  if vim.fn.isdirectory(path) == 1 and #vim.fn.readdir(path) > 0 then
    return false, 'Worktree directory is not empty: ' .. path
  end

  local suffix = string.format('%.0f', vim.loop.hrtime()):sub(-10)
  local worktree_branch = string.format('agent-%s-%s', utils.timestamp(), suffix)
  local command = table.concat({
    'git worktree add -b',
    vim.fn.shellescape(worktree_branch),
    vim.fn.shellescape(path),
    vim.fn.shellescape(branch),
  }, ' ')
  local _, err = run(project_root, command)
  if err then return false, err end

  return true, {
    path = path,
    branch = worktree_branch,
    base_branch = branch,
    created = true,
  }
end

function M.remove_worktree(path, project_root)
  project_root = project_root or utils.get_project_root()
  if not path or path == '' then return false, 'Missing worktree path' end

  local normalized = normalize_path(path)
  local registered = false
  local removable_branch = nil
  for _, worktree in ipairs(M.list_worktrees(project_root)) do
    if normalize_path(worktree.path) == normalized then
      registered = true
      removable_branch = worktree.branch and worktree.branch:match('^refs/heads/(agent%-.+)$') or nil
      break
    end
  end

  if registered then
    local _, err = run(
      project_root,
      'git worktree remove --force ' .. vim.fn.shellescape(path)
    )
    if err then return false, err end
    if removable_branch then
      local _, branch_err = run(
        project_root,
        'git branch -D ' .. vim.fn.shellescape(removable_branch)
      )
      if branch_err then return false, branch_err end
    end
    return true
  end

  if vim.loop.fs_stat(path) then
    local deleted = vim.fn.delete(path, 'rf')
    if deleted ~= 0 then return false, 'Failed to remove directory: ' .. path end
  end
  return true
end

function M.find_stash_oid_by_label(project_root, label)
  if not label or label == '' then return nil end
  local output = run(project_root, "git stash list --format='%H%x09%gs'")
  for line in (output or ''):gmatch('[^\n]+') do
    local oid, subject = line:match('^([0-9a-fA-F]+)\t(.+)$')
    if oid and subject and subject:sub(-#label) == label then return oid end
  end
  return nil
end

function M.stash_push(project_root, label, label_is_unique)
  local before = rev_parse(project_root, 'refs/stash')
  local unique_label = label_is_unique and label or string.format(
      '%s [%s]',
      label,
      string.format('%.0f', vim.loop.hrtime())
    )
  local _, err = run(
    project_root,
    'git stash push --include-untracked --message ' .. vim.fn.shellescape(unique_label)
  )
  if err then return false, err end

  local located_oid = M.find_stash_oid_by_label(project_root, unique_label)
  if located_oid then return true, { oid = located_oid, label = unique_label } end
  local after = rev_parse(project_root, 'refs/stash')
  if after and after ~= before then return true, { oid = after, label = unique_label } end
  return true, nil
end

function M.find_stash_ref(project_root, stash_oid)
  if not stash_oid or stash_oid == '' then return nil end
  if stash_oid:match('^stash@{%d+}$') then return stash_oid end
  local output = run(project_root, "git stash list --format='%gd%x09%H'")
  if not output then return nil end
  for line in output:gmatch('[^\n]+') do
    local ref, oid = line:match('^(stash@{%d+})\t([0-9a-fA-F]+)$')
    if ref and oid and oid:lower() == stash_oid:lower() then return ref end
  end
  return nil
end

function M.apply_stash(project_root, stash_oid, restore_index)
  if not stash_oid or stash_oid == '' then return true end
  local index_flag = restore_index and ' --index' or ''
  local _, err = run(
    project_root,
    'git stash apply' .. index_flag .. ' ' .. vim.fn.shellescape(stash_oid)
  )
  if err then return false, err end
  return true
end

function M.drop_stash(project_root, stash_oid)
  if not stash_oid or stash_oid == '' then return true end
  local ref = M.find_stash_ref(project_root, stash_oid)
  if not ref then return true end
  local _, err = run(project_root, 'git stash drop ' .. vim.fn.shellescape(ref))
  if err then return false, err end
  return true
end

function M.restore_stash(project_root, stash_oid)
  local applied, apply_err = M.apply_stash(project_root, stash_oid, true)
  if not applied then return false, apply_err end
  return M.drop_stash(project_root, stash_oid)
end

function M.add_to_gitignore(pattern, project_root)
  project_root = project_root or utils.get_project_root()
  if not project_root then return false end
  local gitignore_path = project_root .. '/.gitignore'
  local content = utils.read_file(gitignore_path) or ''
  local escaped = vim.pesc(pattern)
  if content:match('^' .. escaped .. '\n') or content:match('\n' .. escaped .. '\n') then
    return true
  end
  if content ~= '' and not content:match('\n$') then content = content .. '\n' end
  return utils.write_file(gitignore_path, content .. pattern .. '\n')
end

function M.current_branch(project_root)
  local result = run(project_root, 'git branch --show-current')
  if not result then return nil end
  result = vim.trim(result)
  return result ~= '' and result or nil
end

function M.default_branch(project_root)
  local result = run(project_root, 'git symbolic-ref refs/remotes/origin/HEAD')
  if result and result ~= '' then
    local branch = result:match('refs/remotes/origin/(.+)')
    if branch then return vim.trim(branch) end
  end

  if rev_parse(project_root, 'refs/heads/main') then return 'main' end
  if rev_parse(project_root, 'refs/heads/master') then return 'master' end
  return M.current_branch(project_root) or 'main'
end

function M.status(path)
  local result = run(path, 'git status --porcelain')
  if not result then return {} end
  local files = {}
  for line in result:gmatch('[^\n]+') do
    local status, file = line:match('^(..) (.+)$')
    if status and file then table.insert(files, { status = status, file = file }) end
  end
  return files
end

function M.diff(path1, path2)
  local command = table.concat({
    'git diff --no-index --name-status',
    vim.fn.shellescape(path1),
    vim.fn.shellescape(path2),
  }, ' ')
  local result = utils.exec(command)
  return result or ''
end

return M
