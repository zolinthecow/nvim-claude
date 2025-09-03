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
    local ref = inline_diff.create_baseline('nvim-claude: baseline ' .. os.date('%Y-%m-%d %H:%M:%S'))
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
  if not git_root then return true end

  -- Ensure baseline exists
  if not inline_diff.get_baseline_ref(git_root) then
    local _ = inline_diff.create_baseline('nvim-claude: baseline (pre-delete)')
  end

  -- If file still exists, update its content in baseline
  if vim.fn.filereadable(file_path) == 1 then
    local content = utils.read_file(file_path) or ''
    local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
    inline_diff.update_baseline_file(git_root, relative, content)
    session.add_edited_file(git_root, relative)
    add_to_session(file_path)
  end

  return true
end

-- Called if deletion failed; untrack the file
function M.untrack_failed_deletion(file_path)
  local git_root = utils.get_project_root_for_file(file_path)
  if not git_root then return true end
  local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  if session.is_edited_file(git_root, relative) then
    session.remove_edited_file(git_root, relative)
  end
  return true
end

-- On user prompt: exit checkpoint preview if active, then checkpoint current state
function M.user_prompt_submit(prompt)
  local checkpoint = require('nvim-claude.checkpoint')
  if checkpoint.is_preview_mode() then
    checkpoint.accept_checkpoint()
  end
  checkpoint.create_checkpoint(prompt)
  return true
end

return M
