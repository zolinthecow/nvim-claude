-- Baseline reference management (commit-based)
-- Responsible for reading, writing, and updating the baseline commit

local M = {}

local utils = require 'nvim-claude.utils'
local persistence = require 'nvim-claude.inline_diff.persistence'
local review_state = require 'nvim-claude.review_state'

local validated_refs = {}

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
  local state = persistence.get_state(git_root) or {}
  if state.baseline_ref or state.stash_ref then
    state.baseline_ref = nil
    state.stash_ref = nil
    persistence.set_state(git_root, state)
  end
  -- Reset edited-file tracking since it is tied to the cleared baseline
  if git_root then
    validated_refs[git_root] = nil
    review_state.clear(git_root)
  end
  utils.exec(string.format(
    'cd %s && git update-ref -d refs/nvim-claude/baseline 2>/dev/null',
    vim.fn.shellescape(git_root)
  ))
end

local function project_root_or_nil()
  local ok, root = pcall(utils.get_project_root)
  if ok and root and root ~= '' then return root end
  return nil
end

-- Get baseline ref for this project from project-state (authoritative).
function M.get_baseline_ref(git_root)
  git_root = git_root or project_root_or_nil()
  if not git_root then return nil end

  local state = persistence.get_state(git_root)
  if state and (state.baseline_ref or state.stash_ref) then
    local persisted_raw = state.baseline_ref or state.stash_ref
    local persisted = sanitize_ref(persisted_raw)
    if persisted then
      if validated_refs[git_root] == persisted then return persisted end
      -- Validate the object actually exists; stale refs cause git errors later
      local exists_cmd = string.format(
        'cd %s && git cat-file -e %s 2>/dev/null',
        vim.fn.shellescape(git_root),
        vim.fn.shellescape(persisted)
      )
      local _, exists_err = utils.exec(exists_cmd)
      if not exists_err then
        validated_refs[git_root] = persisted
        return persisted
      end
      clear_persisted_ref(git_root, persisted_raw, 'missing_object')
      return nil
    end
    clear_persisted_ref(git_root, persisted_raw, 'persistence')
  end

  return nil
end

-- Set baseline ref (project-state is authoritative; git ref is a mirror/pin).
function M.set_baseline_ref(git_root, ref)
  git_root = git_root or project_root_or_nil()
  if not git_root then return false end
  
  -- Validate ref to prevent storing error messages
  if ref and (ref:match('^fatal:') or ref:match('^error:') or not ref:match('^[a-f0-9]+$')) then
    local logger = require('nvim-claude.logger')
    logger.error('baseline', 'Invalid baseline ref rejected', { ref = ref, git_root = git_root })
    return false
  end

  if ref and ref:match('^[a-f0-9]+$') then
    local exists_cmd = string.format(
      'cd %s && git cat-file -e %s 2>/dev/null',
      vim.fn.shellescape(git_root),
      vim.fn.shellescape(ref)
    )
    local _, exists_err = utils.exec(exists_cmd)
    if exists_err then
      local logger = require('nvim-claude.logger')
      logger.error('baseline', 'Invalid baseline ref rejected', { ref = ref, git_root = git_root })
      return false
    end

    -- Persist authoritative baseline first.
    if not persistence.save_state({ baseline_ref = ref }, git_root) then
      return false
    end

    -- Keep git ref as a best-effort mirror/pin.
    local cmd = string.format(
      'cd %s && git update-ref refs/nvim-claude/baseline %s',
      vim.fn.shellescape(git_root),
      vim.fn.shellescape(ref)
    )
    local _, update_err = utils.exec(cmd)
    if update_err then
      local logger = require('nvim-claude.logger')
      logger.warn('baseline', 'Failed to update mirrored baseline ref', {
        ref = ref,
        git_root = git_root,
        error = update_err,
      })
    end
    validated_refs[git_root] = ref
  else
    local state = persistence.get_state(git_root) or {}
    state.baseline_ref = nil
    state.stash_ref = nil
    if not persistence.set_state(git_root, state) then
      return false
    end

    -- Clear mirrored git ref best-effort.
    local cmd = string.format(
      'cd %s && git update-ref -d refs/nvim-claude/baseline 2>/dev/null',
      vim.fn.shellescape(git_root)
    )
    local _, update_err = utils.exec(cmd)
    if update_err then
      local logger = require('nvim-claude.logger')
      logger.warn('baseline', 'Failed to clear mirrored baseline ref', {
        git_root = git_root,
        error = update_err,
      })
    end
    validated_refs[git_root] = nil
  end
  return true
end

-- Clear only the baseline (keeps other inline_diff_state keys, if any)
function M.clear_baseline_ref(git_root)
  return M.set_baseline_ref(git_root, nil)
end

function M.read_file(git_root, relative_path, ref)
  git_root = git_root or project_root_or_nil()
  ref = ref or (git_root and M.get_baseline_ref(git_root))
  if not git_root or not ref or not relative_path then
    return nil, 'missing baseline context'
  end

  local object = ref .. ':' .. relative_path
  local cmd = string.format(
    'cd %s && git show %s',
    vim.fn.shellescape(git_root),
    vim.fn.shellescape(object)
  )
  local content, err = utils.exec(cmd)
  if content ~= nil then
    return { exists = true, content = content }
  end
  if err and (err:match 'does not exist' or err:match 'exists on disk, but not in' or err:match 'Path .+ does not exist') then
    return { exists = false, content = '' }
  end
  return nil, err or 'failed to read baseline file'
end

-- Create a new baseline commit from a snapshot of working dir (without HEAD move)
function M.create_baseline(message, git_root)
  local logger = require('nvim-claude.logger')
  git_root = git_root or project_root_or_nil()
  if not git_root then 
    logger.warn('baseline', 'No git root found for baseline creation')
    return nil 
  end

  -- Build a commit from a temporary index snapshot of the working directory.
  local temp_index = vim.fn.tempname() .. '.index'
  local function cleanup()
    if vim.fn.filereadable(temp_index) == 1 then vim.fn.delete(temp_index) end
  end
  local index_env = 'GIT_INDEX_FILE=' .. vim.fn.shellescape(temp_index) .. ' '
  local _, read_err = utils.exec(string.format(
    'cd %s && (%sgit read-tree HEAD 2>/dev/null || %sgit read-tree --empty)',
    vim.fn.shellescape(git_root),
    index_env,
    index_env
  ))
  if read_err then
    logger.error('baseline', 'Failed to initialize baseline index', { error = read_err, git_root = git_root })
    cleanup()
    return nil
  end
  -- Stage all files into the temp index
  local add_cmd = string.format(
    'cd %s && %sgit add -A',
    vim.fn.shellescape(git_root),
    index_env
  )
  local _, add_err = utils.exec(add_cmd)
  if add_err then 
    logger.error('baseline', 'Failed to stage files for baseline', { error = add_err, git_root = git_root })
    cleanup()
    return nil 
  end
  -- Write tree from temp index
  local tree_cmd = string.format(
    'cd %s && %sgit write-tree',
    vim.fn.shellescape(git_root),
    index_env
  )
  local tree_sha, tree_err = utils.exec(tree_cmd)
  if tree_err or not tree_sha then 
    logger.error('baseline', 'Failed to write tree for baseline', { error = tree_err or 'no tree sha', git_root = git_root })
    cleanup()
    return nil 
  end
  tree_sha = tree_sha:gsub('%s+', '')
  -- Create a commit with no parent (snapshot)
  local commit_cmd = string.format(
    'cd %s && git commit-tree %s -m %s',
    vim.fn.shellescape(git_root),
    vim.fn.shellescape(tree_sha),
    vim.fn.shellescape(message or 'nvim-claude baseline')
  )
  local commit_sha, commit_err = utils.exec(commit_cmd)
  if commit_err or not commit_sha then 
    logger.error('baseline', 'Failed to create baseline commit', { error = commit_err or 'no commit sha', git_root = git_root })
    cleanup()
    return nil 
  end
  commit_sha = commit_sha:gsub('%s+', '')
  -- Validate commit SHA before storing
  if not commit_sha:match('^[a-f0-9]+$') then
    logger.error('baseline', 'Invalid commit SHA from git commit-tree', { commit_sha = commit_sha, git_root = git_root })
    cleanup()
    return nil
  end
  -- Update git ref + persist + cache
  if not M.set_baseline_ref(git_root, commit_sha) then
    cleanup()
    return nil
  end
  cleanup()
  logger.info('baseline', 'Created baseline commit', { commit_sha = commit_sha, git_root = git_root })
  return commit_sha
end

function M.apply_changes(git_root, changes, current_baseline_ref)
  git_root = git_root or project_root_or_nil()
  if not git_root then return false, 'no project root' end
  if not current_baseline_ref or not current_baseline_ref:match '^[a-f0-9]+$' then
    return false, 'invalid baseline ref'
  end
  if not changes or #changes == 0 then return true end

  local temp_dir = vim.fn.tempname()
  local temp_index = temp_dir .. '/index'
  local ok, result = pcall(function()
    if vim.fn.mkdir(temp_dir, 'p') ~= 1 then
      error('failed to create temporary baseline directory')
    end

    local _, read_err = utils.exec(string.format(
      'cd %s && GIT_INDEX_FILE=%s git read-tree %s',
      vim.fn.shellescape(git_root),
      vim.fn.shellescape(temp_index),
      vim.fn.shellescape(current_baseline_ref)
    ))
    if read_err then error('failed to read baseline tree: ' .. read_err) end

    for i, change in ipairs(changes) do
      if not change.relative_path or change.relative_path == '' then
        error('baseline change is missing a relative path')
      end
      if change.exists == false then
        local _, remove_err = utils.exec(string.format(
          'cd %s && GIT_INDEX_FILE=%s git update-index --remove -- %s',
          vim.fn.shellescape(git_root),
          vim.fn.shellescape(temp_index),
          vim.fn.shellescape(change.relative_path)
        ))
        if remove_err then error('failed to remove baseline file: ' .. remove_err) end
      else
        local content_file = temp_dir .. '/content-' .. i
        if not utils.write_file(content_file, change.content or '') then
          error('failed to write temporary baseline content')
        end
        local object, hash_err = utils.exec(string.format(
          'cd %s && git hash-object -w %s',
          vim.fn.shellescape(git_root),
          vim.fn.shellescape(content_file)
        ))
        object = object and object:gsub('%s+$', '') or nil
        if hash_err or not object or not object:match '^[a-f0-9]+$' then
          error('failed to hash baseline content: ' .. (hash_err or 'invalid object id'))
        end
        local _, update_err = utils.exec(string.format(
          'cd %s && GIT_INDEX_FILE=%s git update-index --add --cacheinfo 100644,%s,%s',
          vim.fn.shellescape(git_root),
          vim.fn.shellescape(temp_index),
          object,
          vim.fn.shellescape(change.relative_path)
        ))
        if update_err then error('failed to update baseline file: ' .. update_err) end
      end
    end

    local tree, tree_err = utils.exec(string.format(
      'cd %s && GIT_INDEX_FILE=%s git write-tree',
      vim.fn.shellescape(git_root),
      vim.fn.shellescape(temp_index)
    ))
    tree = tree and tree:gsub('%s+$', '') or nil
    if tree_err or not tree or not tree:match '^[a-f0-9]+$' then
      error('failed to write baseline tree: ' .. (tree_err or 'invalid tree id'))
    end

    local commit, commit_err = utils.exec(string.format(
      'cd %s && git commit-tree %s -p %s -m %s',
      vim.fn.shellescape(git_root),
      tree,
      current_baseline_ref,
      vim.fn.shellescape('nvim-claude: update baseline')
    ))
    commit = commit and commit:gsub('%s+$', '') or nil
    if commit_err or not commit or not commit:match '^[a-f0-9]+$' then
      error('failed to create baseline commit: ' .. (commit_err or 'invalid commit id'))
    end
    if not M.set_baseline_ref(git_root, commit) then
      error('failed to persist baseline ref')
    end
    return commit
  end)

  if vim.fn.isdirectory(temp_dir) == 1 then
    vim.fn.delete(temp_dir, 'rf')
  end
  if not ok then
    require('nvim-claude.logger').error('baseline', 'Failed to update baseline', {
      error = result,
      git_root = git_root,
    })
    return false, tostring(result)
  end
  return true, result
end

function M.update_baseline_with_content(git_root, relative_path, content, current_baseline_ref)
  return M.apply_changes(git_root, {
    { relative_path = relative_path, exists = true, content = content or '' },
  }, current_baseline_ref)
end

function M.remove_from_baseline(git_root, relative_path, current_baseline_ref)
  return M.apply_changes(git_root, {
    { relative_path = relative_path, exists = false },
  }, current_baseline_ref)
end

return M
