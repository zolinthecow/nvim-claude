-- Worktree helpers for background agents: encapsulate branch/stash creation

local M = {}

local utils = require('nvim-claude.utils')
local git = utils.git

local function default_branch()
  return git.current_branch() or git.default_branch()
end

-- Create a worktree at agent_dir based on fork_from
-- fork_from: { type = 'branch'|'stash', branch? }
-- Returns: success:boolean, info|err
-- info = { base_info:string, fork_info:table, worktree:table }
function M.create(agent_dir, fork_from, task)
  local ok, result
  local base_info = ''
  local fork_info = {}

  if fork_from and fork_from.type == 'stash' then
    -- Try to stash current changes (including untracked) in main repo
    local label = 'Agent fork: ' .. (task and task:sub(1, 50) or utils.timestamp())
    local stash_cmd = string.format('git stash push -u -m %s', vim.fn.shellescape(label))
    local stash_result = utils.exec(stash_cmd)

    if stash_result and stash_result:match('Saved working directory') then
      -- Obtain stash ref
      local stash_ref = utils.exec('git rev-parse stash@{0}')
      if stash_ref then stash_ref = stash_ref:gsub('\n', '') end

      -- Create worktree from current branch
      local branch = default_branch()
      ok, result = git.create_worktree(agent_dir, branch)

      if ok and stash_ref and stash_ref ~= '' then
        -- Apply stash in the new worktree using the SHA reference
        local apply_cmd = string.format('cd %s && git stash apply %s', vim.fn.shellescape(agent_dir), stash_ref)
        local apply_result = utils.exec(apply_cmd)
        if apply_result and not apply_result:match('error:') then
          base_info = string.format('Forked from: %s (with stashed changes including untracked files)', branch)
          -- Pop the stash from the main repository since it was successfully applied
          utils.exec('git stash pop')
          fork_info = { type = 'stash', branch = branch }
        else
          base_info = string.format('Forked from: %s (stash apply failed)', branch)
          fork_info = { type = 'branch', branch = branch }
        end
      end
    else
      -- No changes to stash, fall back to branch path
      local branch = default_branch()
      ok, result = git.create_worktree(agent_dir, branch)
      base_info = string.format('Forked from: %s branch (no changes to stash)', branch)
      fork_info = { type = 'branch', branch = branch }
    end
  else
    -- Branch flow
    local branch = (fork_from and fork_from.branch) or default_branch()
    ok, result = git.create_worktree(agent_dir, branch)
    base_info = string.format('Forked from: %s branch', branch)
    fork_info = { type = 'branch', branch = branch }
  end

  if not ok then
    return false, (result or 'Failed to create worktree')
  end

  return true, { base_info = base_info, fork_info = fork_info, worktree = result }
end

function M.remove(path)
  return git.remove_worktree(path)
end

return M
