-- Autocmds to integrate inline diffs into buffer open flows

local M = {}

local utils = require 'nvim-claude.utils'
local review_state = require 'nvim-claude.review_state'
local inline_diff = require 'nvim-claude.inline_diff'

local function show_diff_if_tracked(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == '' then
    return
  end

  local git_root = utils.get_project_root_for_file(file_path)
  if not git_root then
    return
  end

  local baseline_ref = inline_diff.get_baseline_ref(git_root)
  if not baseline_ref or baseline_ref == '' then
    return
  end

  local relative = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
  if not review_state.is_edited_file(git_root, relative) then
    return
  end

  local base = inline_diff.read_baseline_file(git_root, relative, baseline_ref)
  if not base then return end

  local current_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local d = inline_diff.compute_diff(base.content, current_content, {
    old_exists = base.exists,
    new_exists = true,
  })
  if not d then return end
  if not d.hunks or #d.hunks == 0 then
    -- No actual diff vs baseline; untrack stale entry
    review_state.remove_edited_file(git_root, relative)
    return
  end
  inline_diff.show_inline_diff(bufnr, base.content, current_content, {
    diff = d,
    old_exists = base.exists,
    new_exists = true,
    preserve_cursor = true,
  })
end

function M.setup_file_open_autocmd()
  local group = vim.api.nvim_create_augroup('NvimClaudeFileOpen', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = group,
    callback = function(args)
      pcall(show_diff_if_tracked, args.buf)
    end,
  })
end

function M.setup_save_autocmd()
  local group = vim.api.nvim_create_augroup('NvimClaudeSave', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(args)
      pcall(show_diff_if_tracked, args.buf)
    end,
  })
end

function M.setup()
  M.setup_file_open_autocmd()
  M.setup_save_autocmd()
end

return M
