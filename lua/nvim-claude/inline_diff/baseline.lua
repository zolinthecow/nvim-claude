-- Baseline reference management (commit-based)
-- Responsible for reading, writing, and updating the baseline commit

local M = {}

local utils = require 'nvim-claude.utils'
local persistence = require 'nvim-claude.inline_diff.persistence'
local project_state = require 'nvim-claude.project-state'

-- Simple in-process cache keyed by project root
local cache = {}

local function sanitize_ref(ref)
  if not ref then return nil end
  if type(ref) ~= 'string' then ref = tostring(ref) end
  ref = ref:gsub('%s+', '')
  if ref == '' then return nil end
  if not ref:match('^[a-f0-9]+$') then return nil end
  return ref
end

local function clear_persisted_ref(git_root, raw_ref, source)
  local logger = require('nvim-claude.logger')
  logger.warn('baseline', 'Clearing invalid baseline ref', {
    git_root = git_root,
    ref = raw_ref,
    source = source,
  })
  cache[git_root] = nil
  local state = persistence.get_state(git_root) or {}
  if state.baseline_ref or state.stash_ref then
    state.baseline_ref = nil
    state.stash_ref = nil
    persistence.set_state(git_root, state)
  end
  -- Reset edited-file tracking since it is tied to the cleared baseline
  if git_root then
    project_state.set(git_root, 'claude_edited_files', {})
    project_state.set(git_root, 'session_edited_files', {})
  end
  if source == 'git_ref' then
    utils.exec(string.format('cd "%s" && git update-ref -d refs/nvim-claude/baseline 2>/dev/null', git_root))
  end
end

local function project_root_or_nil()
  local ok, root = pcall(utils.get_project_root)
  if ok and root and root ~= '' then return root end
  return nil
end

-- Get baseline ref for this project (reads cache → project-state → git ref)
function M.get_baseline_ref(git_root)
  git_root = git_root or project_root_or_nil()
  if not git_root then return nil end

  if cache[git_root] then
    local cached = sanitize_ref(cache[git_root])
    if cached then
      cache[git_root] = cached
      return cached
    end
    cache[git_root] = nil
  end

  local state = persistence.get_state(git_root)
  if state and (state.baseline_ref or state.stash_ref) then
    local persisted_raw = state.baseline_ref or state.stash_ref
    local persisted = sanitize_ref(persisted_raw)
    if persisted then
      -- Validate the object actually exists; stale refs cause git errors later
      local exists_cmd = string.format('cd "%s" && git cat-file -e %s 2>/dev/null', git_root, persisted)
      local _, exists_err = utils.exec(exists_cmd)
      if not exists_err then
        cache[git_root] = persisted
        return persisted
      end
      clear_persisted_ref(git_root, persisted_raw, 'missing_object')
    end
    clear_persisted_ref(git_root, persisted_raw, 'persistence')
  end

  local ref_cmd = string.format('cd "%s" && git rev-parse refs/nvim-claude/baseline 2>/dev/null', git_root)
  local ref, err = utils.exec(ref_cmd)
  if ref and not err then
    local sanitized = sanitize_ref(ref)
    if sanitized then
      -- Validate object exists
      local exists_cmd = string.format('cd "%s" && git cat-file -e %s 2>/dev/null', git_root, sanitized)
      local _, exists_err = utils.exec(exists_cmd)
      if not exists_err then
        cache[git_root] = sanitized
        persistence.save_state({ baseline_ref = sanitized })
        return sanitized
      end
      clear_persisted_ref(git_root, ref, 'missing_object')
    end
    clear_persisted_ref(git_root, ref, 'git_ref')
  end
  return nil
end

-- Set baseline ref (updates git ref, cache, and persists to project-state)
function M.set_baseline_ref(git_root, ref)
  git_root = git_root or project_root_or_nil()
  if not git_root then return end
  
  -- Validate ref to prevent storing error messages
  if ref and (ref:match('^fatal:') or ref:match('^error:') or not ref:match('^[a-f0-9]+$')) then
    local logger = require('nvim-claude.logger')
    logger.error('baseline', 'Invalid baseline ref rejected', { ref = ref, git_root = git_root })
    return
  end

  cache[git_root] = sanitize_ref(ref)

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
function M.create_baseline(message, git_root)
  local logger = require('nvim-claude.logger')
  git_root = git_root or project_root_or_nil()
  if not git_root then 
    logger.warn('baseline', 'No git root found for baseline creation')
    return nil 
  end

  -- Build a commit from a temporary index snapshot of the working directory
  local temp_index = string.format('/tmp/nvim-claude-baseline-%d.index', os.time())
  -- Copy current index to temp
  utils.exec(string.format('cd "%s" && cp .git/index "%s" 2>/dev/null || true', git_root, temp_index))
  -- Stage all files into the temp index
  local add_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git add -A', git_root, temp_index)
  local _, add_err = utils.exec(add_cmd)
  if add_err then 
    logger.error('baseline', 'Failed to stage files for baseline', { error = add_err, git_root = git_root })
    return nil 
  end
  -- Write tree from temp index
  local tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
  local tree_sha, tree_err = utils.exec(tree_cmd)
  if tree_err or not tree_sha then 
    logger.error('baseline', 'Failed to write tree for baseline', { error = tree_err or 'no tree sha', git_root = git_root })
    return nil 
  end
  tree_sha = tree_sha:gsub('%s+', '')
  -- Create a commit with no parent (snapshot)
  local commit_cmd = string.format('cd "%s" && git commit-tree %s -m "%s"', git_root, tree_sha, message)
  local commit_sha, commit_err = utils.exec(commit_cmd)
  if commit_err or not commit_sha then 
    logger.error('baseline', 'Failed to create baseline commit', { error = commit_err or 'no commit sha', git_root = git_root })
    return nil 
  end
  commit_sha = commit_sha:gsub('%s+', '')
  -- Validate commit SHA before storing
  if not commit_sha:match('^[a-f0-9]+$') then
    logger.error('baseline', 'Invalid commit SHA from git commit-tree', { commit_sha = commit_sha, git_root = git_root })
    return nil
  end
  -- Update git ref + persist + cache
  M.set_baseline_ref(git_root, commit_sha)
  logger.info('baseline', 'Created baseline commit', { commit_sha = commit_sha, git_root = git_root })
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
  local logger = require('nvim-claude.logger')
  git_root = git_root or project_root_or_nil()
  if not git_root then 
    logger.warn('baseline', 'No git root for baseline removal', { relative_path = relative_path })
    return false 
  end
  
  -- Validate current baseline ref
  if not current_baseline_ref or not current_baseline_ref:match('^[a-f0-9]+$') then
    logger.error('baseline', 'Invalid baseline ref for removal', { 
      current_baseline_ref = current_baseline_ref,
      relative_path = relative_path 
    })
    return false
  end

  local temp_dir = '/tmp/nvim-claude-baseline-' .. os.time() .. '-' .. math.random(10000)
  local success, err = pcall(function()
    vim.fn.mkdir(temp_dir, 'p')

    local temp_index = temp_dir .. '/index'
    -- Read the tree from current baseline into temporary index
    local read_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git read-tree %s', git_root, temp_index, current_baseline_ref)
    local _, read_err = utils.exec(read_tree_cmd)
    if read_err then 
      logger.error('baseline', 'Failed to read tree in remove', { error = read_err, baseline_ref = current_baseline_ref })
      error('Failed to read baseline tree: ' .. read_err) 
    end

    -- Remove the specific path from the index
    local rm_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git update-index --remove "%s"', git_root, temp_index, relative_path)
    local _, rm_err = utils.exec(rm_cmd)
    if rm_err then 
      logger.error('baseline', 'Failed to remove from index', { error = rm_err, file = relative_path })
      error('Failed to remove file from index: ' .. rm_err) 
    end

    -- Write new tree and commit
    local write_tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
    local new_tree_hash, tree_err = utils.exec(write_tree_cmd)
    if tree_err or not new_tree_hash then 
      logger.error('baseline', 'Failed to write tree in remove', { error = tree_err or 'no tree hash' })
      error('Failed to write tree: ' .. (tree_err or 'unknown')) 
    end
    new_tree_hash = new_tree_hash:gsub('%s+$', '')

    local commit_message = string.format('nvim-claude: removed %s from baseline at %s', relative_path, os.date('%Y-%m-%d %H:%M:%S'))
    local commit_cmd2 = string.format('cd "%s" && git commit-tree %s -p %s -m "%s"', git_root, new_tree_hash, current_baseline_ref, commit_message)
    local new_commit_hash, commit_err = utils.exec(commit_cmd2)
    if commit_err or not new_commit_hash then 
      logger.error('baseline', 'Failed to create commit in remove', { 
        error = commit_err or 'no commit hash',
        file = relative_path 
      })
      error('Failed to create commit: ' .. (commit_err or 'unknown')) 
    end
    new_commit_hash = new_commit_hash:gsub('%s+$', '')
    
    -- Validate commit hash
    if not new_commit_hash:match('^[a-f0-9]+$') then
      logger.error('baseline', 'Invalid commit hash in remove', { new_commit_hash = new_commit_hash })
      error('Invalid commit hash: ' .. new_commit_hash)
    end

    M.set_baseline_ref(git_root, new_commit_hash)
    logger.info('baseline', 'Removed file from baseline', { file = relative_path, new_ref = new_commit_hash })
  end)

  if vim.fn.isdirectory(temp_dir) == 1 then
    vim.fn.delete(temp_dir, 'rf')
  end

  return success
end

return M
