-- Persistence layer for inline diffs (project-state based)
-- Stores lightweight state per project, including baseline_ref and optional metadata

local M = {}

local utils = require 'nvim-claude.utils'
local project_state = require 'nvim-claude.project-state'

-- Internal: resolve current project root
local function project_root_or_nil()
  local ok, root = pcall(utils.get_project_root)
  if ok and root and root ~= '' then return root end
  return nil
end

-- Read current inline diff state (raw)
function M.get_state(git_root)
  git_root = git_root or project_root_or_nil()
  if not git_root then return nil end
  return project_state.get(git_root, 'inline_diff_state')
end

-- Write inline diff state (raw, replaces entire value)
function M.set_state(git_root, state)
  git_root = git_root or project_root_or_nil()
  if not git_root then return false end
  return project_state.set(git_root, 'inline_diff_state', state)
end

-- Merge and persist state updates (baseline_ref, claude_edited_files, etc.)
function M.save_state(state_data)
  local git_root = project_root_or_nil()
  if not git_root then return false end

  local current = project_state.get(git_root, 'inline_diff_state') or {}

  -- Baseline ref (commit). Migrate away from legacy stash_ref.
  if state_data.baseline_ref then
    current.baseline_ref = state_data.baseline_ref
    current.stash_ref = nil -- legacy cleanup
  end

  -- Optional: mirror edited files (Phase 2 will remove this duplication)
  if state_data.claude_edited_files then
    current.claude_edited_files = state_data.claude_edited_files
  end

  current.timestamp = os.time()
  return project_state.set(git_root, 'inline_diff_state', current)
end

-- Load state and expose for callers (keeps legacy migration visible)
function M.load_state()
  local git_root = project_root_or_nil()
  if not git_root then return nil end
  local state = project_state.get(git_root, 'inline_diff_state')
  return state
end

-- Clear persistence for this project
function M.clear_state(git_root)
  git_root = git_root or project_root_or_nil()
  if not git_root then return false end
  return project_state.set(git_root, 'inline_diff_state', nil)
end

-- Get the path to the global project state file
function M.get_state_file()
  -- project_state exposes get_state_file() for the global JSON
  local ok, path = pcall(project_state.get_state_file)
  if ok then return path end
  return nil
end

return M
