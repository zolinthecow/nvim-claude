local M = {}

local utils = require 'nvim-claude.utils'
local git = utils.git

local function default_branch(project_root)
  return git.current_branch(project_root) or git.default_branch(project_root)
end

local function restore_main_stash(project_root, stash)
  if not stash then return true end
  local applied, apply_err = git.apply_stash(project_root, stash.oid, true)
  if not applied then return false, apply_err end
  local dropped, drop_err = git.drop_stash(project_root, stash.oid)
  if not dropped then return false, drop_err end
  return true
end

function M.create(agent_dir, fork_from, task, project_root)
  project_root = project_root or utils.get_project_root()
  if not project_root then return false, 'No project root found' end

  local branch = (fork_from and fork_from.branch) or default_branch(project_root)
  if not branch then return false, 'No base branch found' end

  if not fork_from or fork_from.type ~= 'stash' then
    local ok, result = git.create_worktree(agent_dir, branch, project_root)
    if not ok then return false, result end
    return true, {
      base_info = string.format('Forked from: %s branch', branch),
      fork_info = { type = 'branch', branch = branch },
      worktree = result,
    }
  end

  local stashed, stash_or_err = git.stash_push(
    project_root,
    'Agent fork: ' .. (task and task:sub(1, 50) or utils.timestamp())
  )
  if not stashed then return false, 'Failed to stash main worktree: ' .. tostring(stash_or_err) end
  local stash = stash_or_err

  local created, result = git.create_worktree(agent_dir, branch, project_root)
  if not created then
    local restored, restore_err = restore_main_stash(project_root, stash)
    if not restored then
      return false, string.format(
        'Worktree creation failed: %s; main worktree recovery failed: %s (stash %s)',
        tostring(result),
        tostring(restore_err),
        stash and stash.oid or 'none'
      )
    end
    return false, result
  end

  if stash then
    local applied, apply_err = git.apply_stash(agent_dir, stash.oid, false)
    if not applied then
      git.remove_worktree(agent_dir, project_root)
      local restored, restore_err = restore_main_stash(project_root, stash)
      if not restored then
        return false, string.format(
          'Failed to apply changes in agent worktree: %s; main recovery failed: %s (stash %s)',
          tostring(apply_err),
          tostring(restore_err),
          stash.oid
        )
      end
      return false, 'Failed to apply changes in agent worktree: ' .. tostring(apply_err)
    end

    local restored, restore_err = git.apply_stash(project_root, stash.oid, true)
    if not restored then
      git.remove_worktree(agent_dir, project_root)
      return false, string.format(
        'Failed to restore main worktree: %s (recovery stash %s retained)',
        tostring(restore_err),
        stash.oid
      )
    end
    local dropped, drop_err = git.drop_stash(project_root, stash.oid)
    if not dropped then
      git.remove_worktree(agent_dir, project_root)
      return false, string.format(
        'Main worktree restored, but failed to remove recovery stash %s: %s',
        stash.oid,
        tostring(drop_err)
      )
    end
  end

  return true, {
    base_info = stash
        and string.format('Forked from: %s (with uncommitted changes)', branch)
      or string.format('Forked from: %s branch (no uncommitted changes)', branch),
    fork_info = { type = stash and 'stash' or 'branch', branch = branch },
    worktree = result,
  }
end

function M.remove(path, project_root)
  return git.remove_worktree(path, project_root)
end

return M
