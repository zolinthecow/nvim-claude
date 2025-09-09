-- Core event handlers (formerly hooks): pre/post tool use, deletions, prompt submit

local M = {}

local utils = require 'nvim-claude.utils'
local inline_diff = require 'nvim-claude.inline_diff'
local session = require 'nvim-claude.events.session'

-- Helper: add file to session_edited_files (persisted per project)
local function add_to_session(file_path)
  if not file_path or file_path == '' then return end
  local git_root = utils.get_project_root_for_file(file_path)
  if not git_root then return end
  session.add_turn_file(git_root, file_path)
end

-- Ensure baseline exists; optionally update baseline file entry with current content
function M.pre_tool_use(file_path)
  -- Resolve project
  local git_root = file_path and utils.get_project_root_for_file(file_path) or utils.get_project_root()
  if not git_root then return true end

  -- Create baseline if missing
  if not inline_diff.get_baseline_ref(git_root) then
    local ref = inline_diff.create_baseline('nvim-claude: baseline ' .. os.date('%Y-%m-%d %H:%M:%S'), git_root)
    if not ref then return true end
  end

  -- If we have a specific file and it exists, update that file in baseline to its current content
  if file_path and vim.fn.filereadable(file_path) == 1 then
    local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
    -- Only update if not already tracked as edited (baseline captured previously)
    if not session.is_edited_file(git_root, relative) then
      local content = utils.read_file(file_path) or ''
      inline_diff.update_baseline_file(git_root, relative, content)
    end
  end

  return true
end

-- After tool use: mark file as edited, persist session, and refresh diff if open
function M.post_tool_use(file_path)
  local git_root = file_path and utils.get_project_root_for_file(file_path) or utils.get_project_root()
  if not git_root then return true end

  if file_path and file_path ~= '' then
    local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
    session.add_edited_file(git_root, relative)
    add_to_session(file_path)

    -- If buffer is loaded, refresh inline diff via façade (schedule to avoid re-entrancy)
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      vim.schedule(function()
        pcall(require('nvim-claude.inline_diff').refresh_inline_diff, bufnr)
      end)
    end
  end

  return true
end

-- Called before rm deletes a file; ensure baseline has latest content and track
function M.track_deleted_file(file_path)
  local git_root = utils.get_project_root_for_file(file_path)
  local logger = require('nvim-claude.logger')
  if not git_root then return true end

  -- Ensure baseline exists
  if not inline_diff.get_baseline_ref(git_root) then
    local _ = inline_diff.create_baseline('nvim-claude: baseline (pre-delete)', git_root)
  end

  -- If file still exists, update its content in baseline
  if vim.fn.filereadable(file_path) == 1 then
    local content = utils.read_file(file_path) or ''
    local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
    inline_diff.update_baseline_file(git_root, relative, content)
    session.add_edited_file(git_root, relative)
    add_to_session(file_path)
    logger.info('track_deleted_file', 'Tracked pre-delete file', { file = relative, project = git_root })
  else
    logger.warn('track_deleted_file', 'File not readable at track time', { file = file_path, project = git_root })
  end

  return true
end

-- Called if deletion failed; untrack the file
function M.untrack_failed_deletion(file_path)
  local git_root = utils.get_project_root_for_file(file_path)
  if not git_root then return true end
  local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  local logger = require('nvim-claude.logger')
  if session.is_edited_file(git_root, relative) then
    session.remove_edited_file(git_root, relative)
    logger.info('untrack_failed_deletion', 'Untracked after failed deletion', { file = relative, project = git_root })
  end
  return true
end

-- On user prompt: exit checkpoint preview if active, then checkpoint current state
function M.user_prompt_submit(prompt)
  local checkpoint = require('nvim-claude.checkpoint')
  local logger = require('nvim-claude.logger')
  -- Try to scope operations to the project implied by TARGET_FILE (set by hook wrapper)
  local target = vim.fn.getenv('TARGET_FILE')
  local git_root_override = nil
  if target and target ~= '' and target ~= vim.NIL then
    local uv = vim.loop
    local stat = (uv and uv.fs_stat) and uv.fs_stat(target) or nil
    if stat and stat.type == 'directory' then
      local cmd = string.format('cd %s && git rev-parse --show-toplevel 2>/dev/null', vim.fn.shellescape(target))
      local out = vim.fn.system(cmd)
      if vim.v.shell_error == 0 and out and out ~= '' then
        git_root_override = out:gsub('%s+$', '')
      else
        git_root_override = target
      end
    else
      git_root_override = require('nvim-claude.utils').get_project_root_for_file(target)
    end
  end
  -- If preview mode is active for this project, accept it first
  if checkpoint.is_preview_mode(git_root_override) then
    checkpoint.accept_checkpoint(git_root_override)
  end
  local id = checkpoint.create_checkpoint(prompt, git_root_override)
  if id then
    local preview = (prompt or ''):gsub('\n',' '):sub(1,50)
    logger.info('user_prompt_submit_hook', 'Created checkpoint', { checkpoint_id = id, prompt_preview = preview })
  else
    logger.warn('user_prompt_submit_hook', 'Failed to create checkpoint')
  end
  return true
end

return M
