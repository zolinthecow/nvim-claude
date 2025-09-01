-- Checkpoint system for nvim-claude
-- Manages git commit checkpoints for Claude Code conversations

local M = {}
local utils = require('nvim-claude.utils')
local logger = require('nvim-claude.logger')
local project_state = require('nvim-claude.project-state')

-- Generate checkpoint ID from timestamp
local function generate_checkpoint_id()
  return 'cp_' .. os.time() .. '_' .. math.random(1000, 9999)
end

-- Get checkpoint ref name from ID
local function get_checkpoint_ref(checkpoint_id)
  return 'refs/nvim-claude/checkpoints/' .. checkpoint_id
end

-- Create a checkpoint commit with all current changes
function M.create_checkpoint(prompt_text)
  local git_root = utils.get_project_root()
  if not git_root then
    logger.error('checkpoint.create_checkpoint', 'No git repository found')
    return nil
  end

  -- Create a temporary index file to avoid polluting the user's staging area
  local temp_index = string.format('/tmp/nvim-claude-checkpoint-%s.index', os.time())
  
  -- Copy current index to temp
  local copy_index_cmd = string.format('cd "%s" && cp .git/index "%s" 2>/dev/null || true', git_root, temp_index)
  utils.exec(copy_index_cmd)
  
  -- Add all files to the temporary index
  local add_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git add -A', git_root, temp_index)
  local add_result, add_err = utils.exec(add_cmd)
  if add_err then
    logger.error('checkpoint.create_checkpoint', 'Failed to stage changes', { error = add_err })
    os.remove(temp_index)
    return nil
  end

  -- Create a tree object from the temporary index
  local tree_cmd = string.format('cd "%s" && GIT_INDEX_FILE="%s" git write-tree', git_root, temp_index)
  local tree_sha, tree_err = utils.exec(tree_cmd)
  
  -- Clean up temp index
  os.remove(temp_index)
  if tree_err then
    logger.error('checkpoint.create_checkpoint', 'Failed to create tree', { error = tree_err })
    return nil
  end
  tree_sha = tree_sha:gsub('%s+', '')

  -- Get current HEAD as parent
  local parent_cmd = string.format('cd "%s" && git rev-parse HEAD', git_root)
  local parent_sha, parent_err = utils.exec(parent_cmd)
  if parent_err then
    logger.error('checkpoint.create_checkpoint', 'Failed to get parent', { error = parent_err })
    return nil
  end
  parent_sha = parent_sha:gsub('%s+', '')

  -- Create commit message
  local timestamp = os.date('%Y-%m-%d %H:%M:%S')
  local prompt_preview = prompt_text and prompt_text:sub(1, 50) or 'No prompt'
  if #prompt_preview < #(prompt_text or '') then
    prompt_preview = prompt_preview .. '...'
  end
  
  local commit_message = string.format('[nvim-claude checkpoint] %s - %s', timestamp, prompt_preview)
  if prompt_text and #prompt_text > #prompt_preview then
    -- Only add full prompt if it was truncated
    commit_message = commit_message .. '\n\n' .. prompt_text
  end

  -- Create commit object without updating HEAD
  local commit_cmd = string.format('cd "%s" && git commit-tree %s -p %s -m %q', 
    git_root, tree_sha, parent_sha, commit_message)
  local commit_sha, commit_err = utils.exec(commit_cmd)
  if commit_err then
    logger.error('checkpoint.create_checkpoint', 'Failed to create commit object', { error = commit_err })
    return nil
  end
  commit_sha = commit_sha:gsub('%s+', '')
  
  -- Create checkpoint ref
  local checkpoint_id = generate_checkpoint_id()
  local ref_cmd = string.format('cd "%s" && git update-ref %s %s', 
    git_root, get_checkpoint_ref(checkpoint_id), commit_sha)
  local _, ref_err = utils.exec(ref_cmd)
  if ref_err then
    logger.error('checkpoint.create_checkpoint', 'Failed to create checkpoint ref', { error = ref_err })
    return nil
  end

  logger.info('checkpoint.create_checkpoint', 'Created checkpoint', {
    checkpoint_id = checkpoint_id,
    sha = commit_sha,
    prompt_preview = prompt_preview
  })

  return checkpoint_id
end

-- List all checkpoints
function M.list_checkpoints()
  local git_root = utils.get_project_root()
  if not git_root then
    return {}
  end

  -- Get only the 5 most recent checkpoint refs with their commit subjects in one command
  local refs_cmd = string.format('cd "%s" && git for-each-ref --sort=-committerdate --count=5 --format="%%(refname:short)\t%%(objectname)\t%%(committerdate:unix)\t%%(subject)" refs/nvim-claude/checkpoints/', git_root)
  local refs_output, refs_err = utils.exec(refs_cmd)
  if refs_err then
    logger.error('checkpoint.list_checkpoints', 'Failed to list refs', { error = refs_err })
    return {}
  end

  local checkpoints = {}
  for line in refs_output:gmatch('[^\n]+') do
    local ref, sha, timestamp, subject = line:match('([^\t]+)\t([^\t]+)\t([^\t]+)\t(.+)')
    if ref and sha and timestamp and subject then
      local checkpoint_id = ref:match('checkpoints/(.+)$')
      if checkpoint_id then
        -- Extract prompt from subject line
        local prompt = subject:match('%- (.+)$') or 'Unknown'
        
        table.insert(checkpoints, {
          id = checkpoint_id,
          timestamp = tonumber(timestamp),
          prompt = prompt,
          commit_sha = sha
        })
      end
    end
  end

  -- Already sorted by git for-each-ref, so just return
  return checkpoints
end

-- Get current checkpoint if in preview mode
function M.get_current_checkpoint()
  local state = M.load_state()
  if state and state.mode == 'preview' then
    return state.preview_checkpoint
  end
  return nil
end

-- Check if in preview mode
function M.is_preview_mode()
  local state = M.load_state()
  return state and state.mode == 'preview'
end

-- Load checkpoint state
function M.load_state()
  local git_root = utils.get_project_root()
  if not git_root then return nil end
  -- Prefer global project-state storage
  local state = project_state.get(git_root, 'checkpoint_state')
  if state and next(state) ~= nil then return state end
  -- Legacy fallback: migrate from local file if present
  local legacy_path = git_root .. '/.nvim-claude/checkpoint-state.json'
  local content = utils.read_file(legacy_path)
  if not content or content == '' then return nil end
  local ok, legacy = pcall(vim.json.decode, content)
  if not ok then
    logger.error('checkpoint.load_state', 'Failed to parse legacy state file', { error = legacy })
    return nil
  end
  -- Save migrated state and optionally remove legacy file
  project_state.set(git_root, 'checkpoint_state', legacy)
  -- Best-effort cleanup
  utils.exec(string.format('rm -f %q', legacy_path))
  return legacy
end

-- Save checkpoint state
function M.save_state(state)
  local git_root = utils.get_project_root()
  if not git_root then return false end
  local ok = project_state.set(git_root, 'checkpoint_state', state or {})
  if not ok then
    logger.error('checkpoint.save_state', 'Failed to save state to project-state')
    return false
  end
  return true
end

-- Enter preview mode for a checkpoint
function M.enter_preview_mode(checkpoint_id)
  logger.info('checkpoint.enter_preview_mode', 'Called with checkpoint_id', { checkpoint_id = checkpoint_id })
  
  local git_root = utils.get_project_root()
  if not git_root then
    vim.notify('No git repository found', vim.log.levels.ERROR)
    return false
  end

  -- Check if another instance is already in preview mode
  local current_state = M.load_state()
  if current_state and current_state.mode == 'preview' then
    vim.notify('Another Neovim instance is browsing checkpoints', vim.log.levels.ERROR)
    return false
  end

  -- Get checkpoint SHA
  local checkpoint_ref = get_checkpoint_ref(checkpoint_id)
  local sha_cmd = string.format('cd "%s" && git rev-parse %s', git_root, checkpoint_ref)
  local checkpoint_sha, sha_err = utils.exec(sha_cmd)
  if sha_err then
    vim.notify('Checkpoint not found: ' .. checkpoint_id, vim.log.levels.ERROR)
    return false
  end
  checkpoint_sha = checkpoint_sha:gsub('%s+', '')

  -- Get current HEAD ref (prefer branch name over SHA)
  local branch_cmd = string.format('cd "%s" && git symbolic-ref --short HEAD 2>/dev/null', git_root)
  local branch_name, branch_err = utils.exec(branch_cmd)
  
  local original_ref
  if not branch_err and branch_name and branch_name ~= '' then
    -- We're on a branch
    original_ref = branch_name:gsub('%s+', '')
  else
    -- We're in detached HEAD, get the SHA
    local sha_cmd = string.format('cd "%s" && git rev-parse HEAD', git_root)
    local sha, _ = utils.exec(sha_cmd)
    original_ref = sha:gsub('%s+', '')
  end

  -- Create stash of current state (including untracked files)
  vim.notify('Stashing current changes...', vim.log.levels.INFO)
  -- First stage untracked files temporarily
  local add_cmd = string.format('cd "%s" && git add -A', git_root)
  local add_result, add_err = utils.exec(add_cmd)
  logger.info('checkpoint.enter_preview_mode', 'Git add result', { result = add_result, error = add_err })
  
  -- Create stash (returns SHA directly)
  local stash_cmd = string.format('cd "%s" && git stash create', git_root)
  local stash_sha, stash_err = utils.exec(stash_cmd)
  logger.info('checkpoint.enter_preview_mode', 'Stash create result', { sha = stash_sha, error = stash_err })
  
  -- Reset the staging area to clean state for checkout
  local reset_cmd = string.format('cd "%s" && git reset --hard HEAD', git_root)
  local reset_result, reset_err = utils.exec(reset_cmd)
  logger.info('checkpoint.enter_preview_mode', 'Git reset result', { result = reset_result, error = reset_err })
  
  local preview_stash = nil
  if stash_sha and stash_sha ~= '' then
    stash_sha = stash_sha:gsub('%s+', '')
    -- Store the stash
    local store_cmd = string.format('cd "%s" && git stash store -m "nvim-claude: preview mode stash" %s', git_root, stash_sha)
    utils.exec(store_cmd)
    preview_stash = stash_sha
    logger.info('checkpoint.enter_preview_mode', 'Created preview stash', { stash = stash_sha })
  end

  -- Checkout the checkpoint
  local checkout_cmd = string.format('cd "%s" && git checkout --detach %s', git_root, checkpoint_sha)
  logger.info('checkpoint.enter_preview_mode', 'About to checkout', { checkpoint_sha = checkpoint_sha })
  local checkout_result, checkout_err = utils.exec(checkout_cmd)
  logger.info('checkpoint.enter_preview_mode', 'Checkout result', { result = checkout_result, error = checkout_err })
  if checkout_err then
    vim.notify('Failed to checkout checkpoint: ' .. checkout_err, vim.log.levels.ERROR)
    return false
  end

  -- Save state
  local state = {
    mode = 'preview',
    preview_checkpoint = checkpoint_id,
    original_ref = original_ref,
    preview_stash = preview_stash,
    entered_at = os.time()
  }
  M.save_state(state)

  vim.notify('Entered preview mode for checkpoint: ' .. checkpoint_id, vim.log.levels.INFO)
  return true
end

-- Exit preview mode and return to original state
function M.exit_preview_mode()
  local state = M.load_state()
  if not state or state.mode ~= 'preview' then
    vim.notify('Not in preview mode', vim.log.levels.WARN)
    return false
  end

  local git_root = utils.get_project_root()
  if not git_root then
    return false
  end

  -- Checkout original ref
  local checkout_cmd = string.format('cd "%s" && git checkout %s', git_root, state.original_ref)
  local _, checkout_err = utils.exec(checkout_cmd)
  if checkout_err then
    vim.notify('Failed to return to original state: ' .. checkout_err, vim.log.levels.ERROR)
    return false
  end

  -- Restore stash if we have one
  if state.preview_stash then
    vim.notify('Restoring stashed changes...', vim.log.levels.INFO)
    -- Apply the specific stash SHA
    local apply_cmd = string.format('cd "%s" && git stash apply %s', git_root, state.preview_stash)
    local _, apply_err = utils.exec(apply_cmd)
    if apply_err then
      vim.notify('Failed to restore stashed changes: ' .. apply_err, vim.log.levels.ERROR)
      -- Don't return false - we still exited preview mode
    else
      -- Drop the stash after successful apply
      local drop_cmd = string.format('cd "%s" && git stash drop %s', git_root, state.preview_stash)
      utils.exec(drop_cmd)
    end
  end

  -- Clear state
  M.save_state({})
  
  vim.notify('Exited preview mode', vim.log.levels.INFO)
  return true
end

-- Accept current checkpoint (exit preview without restoring stash)
function M.accept_checkpoint()
  local state = M.load_state()
  if not state or state.mode ~= 'preview' then
    vim.notify('Not in preview mode', vim.log.levels.WARN)
    return false
  end

  -- Drop the stash if we have one
  if state.preview_stash then
    local git_root = utils.get_project_root()
    if git_root then
      local drop_cmd = string.format('cd "%s" && git stash drop %s', git_root, state.preview_stash)
      utils.exec(drop_cmd)
    end
  end
  
  -- Reset inline diff state since we're accepting a checkpoint
  -- There should be no diffs after accepting a checkpoint
  local inline_diff = require('nvim-claude.inline_diff')
  local events = require('nvim-claude.events')
  local git_root = utils.get_project_root()
  
  if git_root then
    inline_diff.clear_baseline_ref(git_root)
    events.clear_edited_files(git_root)
    inline_diff.clear_persistence(git_root)
  else
    inline_diff.clear_baseline_ref()
    inline_diff.clear_persistence()
  end
  -- Close any active inline diffs in buffers (via façade)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and inline_diff.has_active_diff and inline_diff.has_active_diff(bufnr) then
      inline_diff.close_inline_diff(bufnr)
    end
  end
  
  logger.info('checkpoint.accept_checkpoint', 'Reset inline diff state after accepting checkpoint')

  -- Get current HEAD SHA before we move
  local git_root = utils.get_project_root()
  if git_root then
    local current_sha_cmd = string.format('cd "%s" && git rev-parse HEAD', git_root)
    local current_sha, _ = utils.exec(current_sha_cmd)
    if current_sha then
      current_sha = current_sha:gsub('%s+', '')
    end
    
    -- If original_ref is a branch name, create a merge commit
    if state.original_ref and not state.original_ref:match('^%x+$') then
      -- First, checkout the original branch
      local checkout_cmd = string.format('cd "%s" && git checkout %s', git_root, state.original_ref)
      local _, checkout_err = utils.exec(checkout_cmd)
      
      if not checkout_err then
        -- Create a merge commit from the checkpoint
        local merge_msg = string.format('Merge checkpoint %s', state.preview_checkpoint or 'unknown')
        local merge_cmd = string.format('cd "%s" && git merge --no-ff %s -m "%s"', 
          git_root, current_sha, merge_msg)
        local _, merge_err = utils.exec(merge_cmd)
        
        if not merge_err then
          vim.notify(string.format('Created merge commit on %s', state.original_ref), vim.log.levels.INFO)
          vim.notify('You can revert this merge if needed with: git revert -m 1 HEAD', vim.log.levels.INFO)
        else
          logger.error('checkpoint.accept_checkpoint', 'Merge failed', { error = merge_err })
          vim.notify('Merge failed - staying at checkpoint', vim.log.levels.ERROR)
          -- Go back to the checkpoint
          local back_cmd = string.format('cd "%s" && git checkout %s', git_root, current_sha)
          utils.exec(back_cmd)
        end
      else
        logger.error('checkpoint.accept_checkpoint', 'Failed to checkout original branch', { error = checkout_err })
      end
    else
      -- Not on a branch originally, create a new branch
      local new_branch = string.format('from-%s', state.preview_checkpoint or 'checkpoint')
      local branch_cmd = string.format('cd "%s" && git checkout -b %s', git_root, new_branch)
      local _, branch_err = utils.exec(branch_cmd)
      
      if not branch_err then
        vim.notify(string.format('Created new branch: %s', new_branch), vim.log.levels.INFO)
      else
        vim.notify('Staying in detached HEAD at checkpoint', vim.log.levels.WARN)
      end
    end
  end
  
  -- Clear state
  M.save_state({})
  
  vim.notify('Accepted checkpoint: ' .. state.preview_checkpoint, vim.log.levels.INFO)
  return true
end

-- Restore a checkpoint (convenience function)
function M.restore_checkpoint(checkpoint_id, opts)
  opts = opts or {}
  
  logger.info('checkpoint.restore_checkpoint', 'Called with checkpoint_id', { checkpoint_id = checkpoint_id })
  
  if M.is_preview_mode() then
    -- Already in preview mode, just checkout different checkpoint
    local git_root = utils.get_project_root()
    if not git_root then
      return false
    end

    local checkpoint_ref = get_checkpoint_ref(checkpoint_id)
    local sha_cmd = string.format('cd "%s" && git rev-parse %s', git_root, checkpoint_ref)
    local checkpoint_sha, sha_err = utils.exec(sha_cmd)
    if sha_err then
      vim.notify('Checkpoint not found: ' .. checkpoint_id, vim.log.levels.ERROR)
      return false
    end
    checkpoint_sha = checkpoint_sha:gsub('%s+', '')

    local checkout_cmd = string.format('cd "%s" && git checkout --detach %s', git_root, checkpoint_sha)
    local _, checkout_err = utils.exec(checkout_cmd)
    if checkout_err then
      vim.notify('Failed to checkout checkpoint: ' .. checkout_err, vim.log.levels.ERROR)
      return false
    end

    -- Update state
    local state = M.load_state()
    state.preview_checkpoint = checkpoint_id
    M.save_state(state)

    vim.notify('Switched to checkpoint: ' .. checkpoint_id, vim.log.levels.INFO)
    return true
  else
    -- Not in preview mode, enter it
    return M.enter_preview_mode(checkpoint_id)
  end
end

return M
