-- Baseline reference management (commit-based)
-- Responsible for reading, writing, and updating the baseline commit

local M = {}

local utils = require 'nvim-claude.utils'
local persistence = require 'nvim-claude.inline_diff.persistence'

-- Simple in-process cache keyed by project root
local cache = {}

local function project_root_or_nil()
  local ok, root = pcall(utils.get_project_root)
  if ok and root and root ~= '' then return root end
  return nil
end

-- Get baseline ref for this project (reads cache → project-state → git ref)
function M.get_baseline_ref(git_root)
  git_root = git_root or project_root_or_nil()
  if not git_root then return nil end

  if cache[git_root] then return cache[git_root] end

  local state = persistence.get_state(git_root)
  if state and (state.baseline_ref or state.stash_ref) then
    local ref = state.baseline_ref or state.stash_ref
    cache[git_root] = ref
    return ref
  end

  local ref_cmd = string.format('cd "%s" && git rev-parse refs/nvim-claude/baseline 2>/dev/null', git_root)
  local ref, err = utils.exec(ref_cmd)
  if ref and not err then
    ref = ref:gsub('%s+', '')
    if ref ~= '' and ref:match('^[a-f0-9]+$') then
      cache[git_root] = ref
      return ref
    end
  end
  return nil
end

-- Set baseline ref (updates git ref, cache, and persists to project-state)
function M.set_baseline_ref(git_root, ref)
  git_root = git_root or project_root_or_nil()
  if not git_root then return end

  cache[git_root] = ref

  if ref and ref:match('^[a-f0-9]+$') then
    local cmd = string.format('cd "%s" && git update-ref refs/nvim-claude/baseline %s', git_root, ref)
    utils.exec(cmd)
    persistence.save_state({ baseline_ref = ref })
  else
    -- Clear git ref
    local cmd = string.format('cd "%s" && git update-ref -d refs/nvim-claude/baseline 2>/dev/null', git_root)
    utils.exec(cmd)
    local state = persistence.get_state(git_root) or {}
    state.baseline_ref = nil
    state.stash_ref = nil
    persistence.set_state(git_root, state)
  end
end

-- Clear only the baseline (keeps other inline_diff_state keys, if any)
function M.clear_baseline_ref(git_root)
  M.set_baseline_ref(git_root, nil)
end

-- Create a new baseline commit from a snapshot of working dir (without HEAD move)
function M.create_baseline(message)
  local git_root = project_root_or_nil()
  if not git_root then return nil end

  -- Build a commit from a temporary index snapshot of the working directory
  local temp_index = string.format('/tmp/nvim-claude-baseline-%d.index', os.time())
  -- Copy current index to temp
  utils.exec(string.format('cd "%s" && cp .git/index "%s" 2>/dev/null || true', git_root, temp_index))
  -- Stage all files into the temp index
  local add_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git add -A', git_root, temp_index)
  local _, add_err = utils.exec(add_cmd)
  if add_err then return nil end
  -- Write tree from temp index
  local tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
  local tree_sha, tree_err = utils.exec(tree_cmd)
  if tree_err or not tree_sha then return nil end
  tree_sha = tree_sha:gsub('%s+', '')
  -- Create a commit with no parent (snapshot)
  local commit_cmd = string.format('cd "%s" && git commit-tree %s -m "%s"', git_root, tree_sha, message)
  local commit_sha, commit_err = utils.exec(commit_cmd)
  if commit_err or not commit_sha then return nil end
  commit_sha = commit_sha:gsub('%s+', '')
  -- Update git ref + persist + cache
  M.set_baseline_ref(git_root, commit_sha)
  return commit_sha
end

-- Update baseline commit tree for a specific file path with provided content
-- Returns true on success
function M.update_baseline_with_content(git_root, relative_path, content, current_baseline_ref)
  git_root = git_root or project_root_or_nil()
  if not git_root then return false end

  local temp_dir = '/tmp/nvim-claude-baseline-' .. os.time() .. '-' .. math.random(10000)
  local success, err = pcall(function()
    vim.fn.mkdir(temp_dir, 'p')

    -- Set up temporary index file
    local temp_index = temp_dir .. '/index'

    -- Read the tree from current baseline into temporary index
    local read_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git read-tree %s', git_root, temp_index, current_baseline_ref)
    local _, read_err = utils.exec(read_tree_cmd)
    if read_err then error('Failed to read baseline tree: ' .. read_err) end

    -- Write content to temporary file
    local temp_file = temp_dir .. '/content'
    utils.write_file(temp_file, content)

    -- Update the specific file in the temporary index
    local update_cmd = string.format(
      'cd "%s" && GIT_INDEX_FILE="%s" git update-index --add --cacheinfo 100644,$(git hash-object -w "%s"),"%s"',
      git_root,
      temp_index,
      temp_file,
      relative_path
    )
    local _, update_err = utils.exec(update_cmd)
    if update_err then error('Failed to update file in index: ' .. update_err) end

    -- Create tree from temporary index
    local write_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
    local new_tree_hash, tree_err = utils.exec(write_tree_cmd)
    if tree_err or not new_tree_hash then error('Failed to write tree: ' .. (tree_err or 'unknown error')) end
    new_tree_hash = new_tree_hash:gsub('%s+$', '')

    -- Create new commit
    local commit_message = string.format('nvim-claude: updated baseline for %s at %s', relative_path, os.date '%Y-%m-%d %H:%M:%S')
    local commit_cmd2 = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', git_root, new_tree_hash, current_baseline_ref, commit_message)
    local new_commit_hash, commit_err = utils.exec(commit_cmd2)
    if commit_err or not new_commit_hash then error('Failed to create commit: ' .. (commit_err or 'unknown error')) end
    new_commit_hash = new_commit_hash:gsub('%s+$', '')

    -- Update baseline ref/cache/persist
    M.set_baseline_ref(git_root, new_commit_hash)
  end)

  -- Cleanup temp directory
  if vim.fn.isdirectory(temp_dir) == 1 then
    vim.fn.delete(temp_dir, 'rf')
  end

  return success
end

-- Remove a file from the baseline commit tree and advance the baseline ref
function M.remove_from_baseline(git_root, relative_path, current_baseline_ref)
  git_root = git_root or project_root_or_nil()
  if not git_root then return false end

  local temp_dir = '/tmp/nvim-claude-baseline-' .. os.time() .. '-' .. math.random(10000)
  local success, err = pcall(function()
    vim.fn.mkdir(temp_dir, 'p')

    local temp_index = temp_dir .. '/index'
    -- Read the tree from current baseline into temporary index
    local read_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git read-tree %s', git_root, temp_index, current_baseline_ref)
    local _, read_err = utils.exec(read_tree_cmd)
    if read_err then error('Failed to read baseline tree: ' .. read_err) end

    -- Remove the specific path from the index
    local rm_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git update-index --remove "%s"', git_root, temp_index, relative_path)
    local _, rm_err = utils.exec(rm_cmd)
    if rm_err then error('Failed to remove file from index: ' .. rm_err) end

    -- Write new tree and commit
    local write_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
    local new_tree_hash, tree_err = utils.exec(write_tree_cmd)
    if tree_err or not new_tree_hash then error('Failed to write tree: ' .. (tree_err or 'unknown')) end
    new_tree_hash = new_tree_hash:gsub('%s+$', '')

    local commit_message = string.format('nvim-claude: removed %s from baseline at %s', relative_path, os.date('%Y-%m-%d %H:%M:%S'))
    local commit_cmd2 = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', git_root, new_tree_hash, current_baseline_ref, commit_message)
    local new_commit_hash, commit_err = utils.exec(commit_cmd2)
    if commit_err or not new_commit_hash then error('Failed to create commit: ' .. (commit_err or 'unknown')) end
    new_commit_hash = new_commit_hash:gsub('%s+$', '')

    M.set_baseline_ref(git_root, new_commit_hash)
  end)

  if vim.fn.isdirectory(temp_dir) == 1 then
    vim.fn.delete(temp_dir, 'rf')
  end

  return success
end

return M
