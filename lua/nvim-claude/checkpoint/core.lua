local M = {}

local utils = require 'nvim-claude.utils'
local git = utils.git
local logger = require 'nvim-claude.logger'
local project_state = require 'nvim-claude.project-state'

local function resolve_git_root(git_root_override)
  if git_root_override and git_root_override ~= '' then return git_root_override end
  local current_file = ''
  pcall(function() current_file = vim.api.nvim_buf_get_name(0) or '' end)
  if current_file ~= '' then
    local root = utils.get_project_root_for_file(current_file)
    if root and root ~= '' then return root end
  end
  return utils.get_project_root()
end

local function run_git(git_root, command)
  return utils.exec('cd ' .. vim.fn.shellescape(git_root) .. ' && ' .. command)
end

local function rev_parse(git_root, ref)
  local output, err = run_git(
    git_root,
    'git rev-parse --verify ' .. vim.fn.shellescape(ref)
  )
  if err or not output then return nil, err end
  return vim.trim(output), nil
end

local function generate_checkpoint_id()
  return string.format('cp_%d_%s', os.time(), string.format('%.0f', vim.loop.hrtime()):sub(-10))
end

local function get_checkpoint_ref(checkpoint_id)
  return 'refs/nvim-claude/checkpoints/' .. checkpoint_id
end

local function checkpoint_sha(git_root, checkpoint_id)
  return rev_parse(git_root, get_checkpoint_ref(checkpoint_id) .. '^{commit}')
end

local function stash_oid(state)
  return state and (state.stash_oid or state.preview_stash) or nil
end

local function resolve_stash_oid(git_root, state)
  local oid = stash_oid(state)
  if oid or not state or not state.stash_label then return oid end
  oid = git.find_stash_oid_by_label(git_root, state.stash_label)
  if oid then
    state.stash_oid = oid
    state.preview_stash = oid
    M.save_state(state, git_root)
  end
  return oid
end

local accept_completed
local finish_accept

local function save_phase(git_root, state, mode)
  state.mode = mode
  state.updated_at = os.time()
  return M.save_state(state, git_root)
end

local function clear_state(git_root)
  return M.save_state({}, git_root)
end

local function checkout_original(git_root, state)
  local branch = state.original_branch
  if not branch and state.original_ref and state.original_ref ~= '' then
    local branch_ref = rev_parse(git_root, 'refs/heads/' .. state.original_ref)
    if branch_ref then branch = state.original_ref end
  end

  local command
  if branch then
    command = 'git checkout ' .. vim.fn.shellescape(branch)
  else
    local target = state.original_head or state.original_ref
    if not target or target == '' then return false, 'Original ref is missing' end
    command = 'git checkout --detach ' .. vim.fn.shellescape(target)
  end
  local _, err = run_git(git_root, command)
  return err == nil, err
end

local function drop_transaction_stash(git_root, state)
  local oid = resolve_stash_oid(git_root, state)
  if not oid then return true end
  local ok, err = git.drop_stash(git_root, oid)
  if not ok then
    logger.error('checkpoint', 'Failed to remove recovery stash', { error = err, stash_oid = oid })
    return false, err
  end
  return true
end

local function restore_transaction(git_root, state)
  if state.mode == 'restored_cleanup_pending' then
    local dropped, drop_err = drop_transaction_stash(git_root, state)
    if not dropped then return false, drop_err end
    return clear_state(git_root)
  end

  if state.mode == 'restore_failed' or state.mode == 'restoring_stash' then
    return false, string.format(
      'Checkpoint recovery requires manual resolution; recovery stash: %s',
      stash_oid(state) or 'none'
    )
  end

  local checked_out, checkout_err = checkout_original(git_root, state)
  if not checked_out then return false, checkout_err end

  local oid = resolve_stash_oid(git_root, state)
  if oid then
    if not save_phase(git_root, state, 'restoring_stash') then
      return false, 'Failed to persist checkpoint recovery phase'
    end
    local applied, apply_err = git.apply_stash(git_root, oid, true)
    if not applied then
      save_phase(git_root, state, 'restore_failed')
      return false, apply_err
    end
  end

  if not save_phase(git_root, state, 'restored_cleanup_pending') then
    return false, 'Worktree restored, but recovery state could not be updated'
  end
  local dropped, drop_err = drop_transaction_stash(git_root, state)
  if not dropped then return false, drop_err end
  if not clear_state(git_root) then return false, 'Failed to clear checkpoint state' end
  return true
end

local function rollback_entry(git_root, state, reason)
  local restored, restore_err = restore_transaction(git_root, state)
  if not restored then
    save_phase(git_root, state, 'restore_failed')
    logger.error('checkpoint.enter_preview_mode', 'Preview entry rollback failed', {
      reason = reason,
      recovery_error = restore_err,
      stash_oid = stash_oid(state),
    })
    return false, string.format('%s; rollback failed: %s', reason, restore_err or 'unknown')
  end
  return false, reason
end

function M.create_checkpoint(prompt_text, git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then
    logger.error('checkpoint.create_checkpoint', 'No git repository found')
    return nil
  end
  local active_state = M.load_state(git_root)
  if active_state then
    logger.warn('checkpoint.create_checkpoint', 'Refusing to checkpoint during active transaction', {
      mode = active_state.mode,
      checkpoint = active_state.preview_checkpoint,
    })
    return nil
  end

  local parent_sha, parent_err = rev_parse(git_root, 'HEAD^{commit}')
  if not parent_sha then
    logger.error('checkpoint.create_checkpoint', 'Failed to resolve HEAD', { error = parent_err })
    return nil
  end

  local temp_index = vim.fn.tempname() .. '.index'
  local index_env = 'GIT_INDEX_FILE=' .. vim.fn.shellescape(temp_index) .. ' '
  local _, read_err = run_git(git_root, index_env .. 'git read-tree ' .. vim.fn.shellescape(parent_sha))
  if read_err then
    os.remove(temp_index)
    logger.error('checkpoint.create_checkpoint', 'Failed to initialize temporary index', { error = read_err })
    return nil
  end

  local _, add_err = run_git(git_root, index_env .. 'git add -A')
  if add_err then
    os.remove(temp_index)
    logger.error('checkpoint.create_checkpoint', 'Failed to stage checkpoint snapshot', { error = add_err })
    return nil
  end

  local tree_sha, tree_err = run_git(git_root, index_env .. 'git write-tree')
  os.remove(temp_index)
  if tree_err or not tree_sha then
    logger.error('checkpoint.create_checkpoint', 'Failed to create checkpoint tree', { error = tree_err })
    return nil
  end
  tree_sha = vim.trim(tree_sha)

  local prompt = prompt_text or 'No prompt'
  local preview = prompt:gsub('[\r\n]+', ' '):sub(1, 50)
  if #prompt > 50 then preview = preview .. '...' end
  local message = string.format(
    '[nvim-claude checkpoint] %s - %s\n\n%s',
    os.date('%Y-%m-%d %H:%M:%S'),
    preview,
    prompt
  )
  local message_file = utils.write_temp_file(message)
  if not message_file then return nil end

  local commit_sha, commit_err = run_git(
    git_root,
    table.concat({
      'git commit-tree',
      vim.fn.shellescape(tree_sha),
      '-p',
      vim.fn.shellescape(parent_sha),
      '-F',
      vim.fn.shellescape(message_file),
    }, ' ')
  )
  os.remove(message_file)
  if commit_err or not commit_sha then
    logger.error('checkpoint.create_checkpoint', 'Failed to create checkpoint commit', { error = commit_err })
    return nil
  end
  commit_sha = vim.trim(commit_sha)

  local checkpoint_id = generate_checkpoint_id()
  local _, ref_err = run_git(
    git_root,
    table.concat({
      'git update-ref',
      vim.fn.shellescape(get_checkpoint_ref(checkpoint_id)),
      vim.fn.shellescape(commit_sha),
    }, ' ')
  )
  if ref_err then
    logger.error('checkpoint.create_checkpoint', 'Failed to create checkpoint ref', { error = ref_err })
    return nil
  end
  return checkpoint_id
end

function M.list_checkpoints(git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then return {} end
  local output, err = run_git(
    git_root,
    "git for-each-ref --sort=-committerdate --count=5 --format='%(refname:short)%09%(objectname)%09%(committerdate:unix)%09%(subject)' refs/nvim-claude/checkpoints/"
  )
  if err or not output then return {} end

  local checkpoints = {}
  for line in output:gmatch('[^\n]+') do
    local ref, sha, timestamp, subject = line:match('([^\t]+)\t([^\t]+)\t([^\t]+)\t(.+)')
    local id = ref and ref:match('checkpoints/(.+)$')
    if id then
      table.insert(checkpoints, {
        id = id,
        timestamp = tonumber(timestamp),
        prompt = subject:match('%- (.+)$') or 'Unknown',
        commit_sha = sha,
      })
    end
  end
  return checkpoints
end

function M.get_current_checkpoint(git_root)
  local state = M.load_state(git_root)
  return state and state.mode == 'preview' and state.preview_checkpoint or nil
end

function M.is_preview_mode(git_root)
  local state = M.load_state(git_root)
  return state and state.mode == 'preview' or false
end

function M.load_state(git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then return nil end
  local state = project_state.get(git_root, 'checkpoint_state')
  if state and next(state) ~= nil then return state end

  local legacy_path = git_root .. '/.nvim-claude/checkpoint-state.json'
  local content = utils.read_file(legacy_path)
  if not content or content == '' then return nil end
  local ok, legacy = pcall(vim.json.decode, content)
  if not ok or type(legacy) ~= 'table' then return nil end
  if not project_state.set(git_root, 'checkpoint_state', legacy) then return nil end
  os.remove(legacy_path)
  return legacy
end

function M.save_state(state, git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then return false end
  return project_state.set(git_root, 'checkpoint_state', state or {})
end

function M.enter_preview_mode(checkpoint_id, git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then return false end
  if M.load_state(git_root) then
    vim.notify('Checkpoint transaction already active; return or recover it first', vim.log.levels.ERROR)
    return false
  end

  local target_sha, target_err = checkpoint_sha(git_root, checkpoint_id)
  if not target_sha then
    vim.notify('Checkpoint not found: ' .. checkpoint_id, vim.log.levels.ERROR)
    logger.error('checkpoint.enter_preview_mode', 'Checkpoint resolution failed', { error = target_err })
    return false
  end

  local original_head, head_err = rev_parse(git_root, 'HEAD^{commit}')
  if not original_head then
    logger.error('checkpoint.enter_preview_mode', 'Failed to resolve original HEAD', { error = head_err })
    return false
  end
  local original_branch = git.current_branch(git_root)
  local transaction = {
    mode = 'entering',
    preview_checkpoint = checkpoint_id,
    checkpoint_sha = target_sha,
    original_branch = original_branch,
    original_head = original_head,
    original_ref = original_branch or original_head,
    stash_label = string.format(
      'nvim-claude checkpoint preview %s [%s]',
      checkpoint_id,
      string.format('%.0f', vim.loop.hrtime())
    ),
    entered_at = os.time(),
  }
  if not M.save_state(transaction, git_root) then return false end

  local stashed, stash_or_err = git.stash_push(
    git_root,
    transaction.stash_label,
    true
  )
  if not stashed then
    clear_state(git_root)
    logger.error('checkpoint.enter_preview_mode', 'Failed to stash worktree', { error = stash_or_err })
    return false
  end
  if stash_or_err then
    transaction.stash_oid = stash_or_err.oid
    transaction.preview_stash = stash_or_err.oid
    if not M.save_state(transaction, git_root) then
      rollback_entry(git_root, transaction, 'Failed to persist recovery stash')
      return false
    end
  end

  local _, checkout_err = run_git(
    git_root,
    'git checkout --detach ' .. vim.fn.shellescape(target_sha)
  )
  if checkout_err then
    local _, rollback_err = rollback_entry(git_root, transaction, checkout_err)
    vim.notify('Failed to enter checkpoint preview: ' .. tostring(rollback_err), vim.log.levels.ERROR)
    return false
  end

  if not save_phase(git_root, transaction, 'preview') then
    rollback_entry(git_root, transaction, 'Failed to persist preview state')
    return false
  end
  vim.notify('Entered preview mode for checkpoint: ' .. checkpoint_id, vim.log.levels.INFO)
  return true
end

function M.exit_preview_mode(git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then return false end
  local state = M.load_state(git_root)
  if not state then
    vim.notify('Not in preview mode', vim.log.levels.WARN)
    return false
  end

  if state.mode == 'accepted_cleanup_pending' then
    return finish_accept(git_root, state)
  end
  if state.mode == 'accepting' and accept_completed and accept_completed(git_root, state) then
    return finish_accept(git_root, state)
  end

  local restored, err = restore_transaction(git_root, state)
  if not restored then
    vim.notify('Failed to return from checkpoint preview: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  vim.notify('Exited preview mode', vim.log.levels.INFO)
  return true
end

local function clear_review_state(git_root)
  local inline_diff = require 'nvim-claude.inline_diff'
  local review_state = require 'nvim-claude.review_state'
  inline_diff.clear_baseline_ref(git_root)
  inline_diff.clear_persistence(git_root)
  review_state.clear(git_root)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr)
        and inline_diff.has_active_diff
        and inline_diff.has_active_diff(bufnr)
    then
      inline_diff.close_inline_diff(bufnr)
    end
  end
end

accept_completed = function(git_root, state)
  local target = state.accept_target_sha
  if not target then return false end
  local head = rev_parse(git_root, 'HEAD^{commit}')
  if not head then return false end
  if state.original_branch then
    return git.current_branch(git_root) == state.original_branch
      and head ~= state.original_head
      and run_git(
        git_root,
        'git merge-base --is-ancestor '
          .. vim.fn.shellescape(target)
          .. ' '
          .. vim.fn.shellescape(head)
      ) ~= nil
  end
  return head == target and git.current_branch(git_root) ~= nil
end

finish_accept = function(git_root, state)
  if not save_phase(git_root, state, 'accepted_cleanup_pending') then return false end
  local dropped, drop_err = drop_transaction_stash(git_root, state)
  if not dropped then
    vim.notify('Checkpoint accepted, but recovery stash cleanup failed: ' .. tostring(drop_err), vim.log.levels.ERROR)
    return false
  end
  local ok, err = pcall(clear_review_state, git_root)
  if not ok then
    logger.error('checkpoint.accept_checkpoint', 'Failed to clear review state', { error = err })
    return false
  end
  return clear_state(git_root)
end

function M.accept_checkpoint(git_root)
  git_root = resolve_git_root(git_root)
  if not git_root then return false end
  local state = M.load_state(git_root)
  if not state then return false end
  if not state.original_branch and state.original_ref then
    local branch_head = rev_parse(git_root, 'refs/heads/' .. state.original_ref)
    if branch_head then state.original_branch = state.original_ref end
  end
  if state.mode == 'accepted_cleanup_pending' then return finish_accept(git_root, state) end
  if state.mode == 'accepting' and accept_completed(git_root, state) then
    return finish_accept(git_root, state)
  end
  if state.mode ~= 'preview' then
    vim.notify('Checkpoint transaction is in recovery mode: ' .. tostring(state.mode), vim.log.levels.ERROR)
    return false
  end

  local status, status_err = run_git(git_root, 'git status --porcelain')
  if status_err then return false end
  if status and vim.trim(status) ~= '' then
    vim.notify('Checkpoint preview has local changes; commit or discard them before accepting', vim.log.levels.ERROR)
    return false
  end

  local current_sha, sha_err = rev_parse(git_root, 'HEAD^{commit}')
  if not current_sha then return false end
  state.accept_target_sha = current_sha
  if not save_phase(git_root, state, 'accepting') then return false end

  local accepted = false
  local accept_err
  if state.original_branch then
    local checked_out, checkout_err = checkout_original(git_root, state)
    if not checked_out then
      save_phase(git_root, state, 'preview')
      return false
    end
    local _, merge_err = run_git(
      git_root,
      table.concat({
        'git merge --no-ff',
        vim.fn.shellescape(current_sha),
        '-m',
        vim.fn.shellescape('Merge checkpoint ' .. (state.preview_checkpoint or 'unknown')),
      }, ' ')
    )
    if merge_err then
      run_git(git_root, 'git merge --abort')
      local _, back_err = run_git(git_root, 'git checkout --detach ' .. vim.fn.shellescape(current_sha))
      if back_err then
        save_phase(git_root, state, 'restore_failed')
      else
        save_phase(git_root, state, 'preview')
      end
      accept_err = merge_err
    else
      accepted = true
    end
  else
    local branch = 'from-' .. (state.preview_checkpoint or 'checkpoint'):gsub('[^%w._-]', '-')
    if rev_parse(git_root, 'refs/heads/' .. branch) then
      branch = branch .. '-' .. string.format('%.0f', vim.loop.hrtime()):sub(-6)
    end
    local _, branch_err = run_git(git_root, 'git checkout -b ' .. vim.fn.shellescape(branch))
    if branch_err then
      save_phase(git_root, state, 'preview')
      accept_err = branch_err
    else
      accepted = true
    end
  end

  if not accepted then
    logger.error('checkpoint.accept_checkpoint', 'Failed to accept checkpoint', { error = accept_err, sha = sha_err })
    vim.notify('Failed to accept checkpoint: ' .. tostring(accept_err), vim.log.levels.ERROR)
    return false
  end
  if not finish_accept(git_root, state) then return false end
  vim.notify('Accepted checkpoint: ' .. tostring(state.preview_checkpoint), vim.log.levels.INFO)
  return true
end

function M.restore_checkpoint(checkpoint_id, opts)
  opts = opts or {}
  local git_root = resolve_git_root(opts.git_root)
  if not git_root then return false end
  local state = M.load_state(git_root)
  if not state then return M.enter_preview_mode(checkpoint_id, git_root) end
  if state.mode ~= 'preview' then
    vim.notify('Checkpoint transaction is in recovery mode: ' .. tostring(state.mode), vim.log.levels.ERROR)
    return false
  end

  local target_sha = checkpoint_sha(git_root, checkpoint_id)
  if not target_sha then return false end
  local old_sha = state.checkpoint_sha
  local _, checkout_err = run_git(git_root, 'git checkout --detach ' .. vim.fn.shellescape(target_sha))
  if checkout_err then return false end

  state.preview_checkpoint = checkpoint_id
  state.checkpoint_sha = target_sha
  if not M.save_state(state, git_root) then
    if old_sha then run_git(git_root, 'git checkout --detach ' .. vim.fn.shellescape(old_sha)) end
    return false
  end
  return true
end

return M
