-- Rendering for inline diffs: highlights, signs, and virtual lines

local M = {}

-- Shared namespace (same as original inline-diff.lua)
local ns_id = vim.api.nvim_create_namespace 'nvim_claude_inline_diff'

-- Apply visual indicators for diff with line highlights
-- Expects diff_data = { hunks = { {new_start, old_start, lines = {...}}, ... } }
function M.apply_diff_visualization(bufnr, diff_data)
  if not diff_data or not diff_data.hunks or #diff_data.hunks == 0 then
    return
  end

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Get current buffer lines for reference; ensure at least one line for virtual placement
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #buf_lines == 0 then
    -- Insert a single empty line to allow virt_lines/extmarks to anchor
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '' })
    buf_lines = { '' }
  end

  -- Apply highlights for each hunk
  for i, hunk in ipairs(diff_data.hunks) do
    -- Track which lines in the current buffer correspond to additions/deletions
    local additions = {}
    local deletions = {}

    -- Start from the beginning of the hunk and track line numbers
    local new_line_num = hunk.new_start -- 1-indexed line number in new file
    local old_line_num = hunk.old_start -- 1-indexed line number in old file

    -- Track the anchor line for deletions (where in the new file they should appear)
    -- This is the line in the new file where deletions occurred
    local deletion_anchor = hunk.new_start - 1 -- 0-indexed

    for _, diff_line in ipairs(hunk.lines or {}) do
      if diff_line:match '^%+' then
        -- This is an added line - it exists in the current buffer at new_line_num
        table.insert(additions, new_line_num - 1) -- Convert to 0-indexed for extmarks
        new_line_num = new_line_num + 1
        -- Don't advance old_line_num for additions
      elseif diff_line:match '^%-' then
        -- This is a deleted line - show as virtual text
        -- Use the current position in the new file (before any additions in this hunk)
        table.insert(deletions, {
          line = deletion_anchor, -- 0-indexed, where in new file this deletion belongs
          text = diff_line:sub(2),
        })
        old_line_num = old_line_num + 1
        -- Don't advance new_line_num for deletions
      elseif diff_line:match '^%s' then
        -- Context line - advance both and update deletion anchor
        new_line_num = new_line_num + 1
        old_line_num = old_line_num + 1
        deletion_anchor = new_line_num - 1 -- Update anchor to after context
      end
    end

    -- Apply highlighting for additions
    for _, line_idx in ipairs(additions) do
      if line_idx >= 0 and line_idx < #buf_lines then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
          line_hl_group = 'DiffAdd',
          id = 4000 + i * 1000 + line_idx,
        })
      end
    end

    -- Show deletions as a single virt_lines block for stability (multiple lines)
    if #deletions > 0 then
      -- Use first addition line if available, otherwise use the deletion's anchor position
      local anchor = (#additions > 0 and additions[1]) or deletions[1].line
      if anchor < 0 then anchor = 0 end
      if anchor >= #buf_lines then anchor = math.max(0, #buf_lines - 1) end

      local win_width = vim.api.nvim_win_get_width(0)
      local virt_lines = {}
      for j, del in ipairs(deletions) do
        local text = '- ' .. del.text
        local parts = {}
        table.insert(parts, { text, 'DiffDelete' })
        if j == 1 and #additions == 0 then
          local hint = ' [Hunk ' .. i .. '/' .. #diff_data.hunks .. ']'
          table.insert(parts, { hint, 'Comment' })
          local used = vim.fn.strdisplaywidth(text) + vim.fn.strdisplaywidth(hint)
          local pad = string.rep(' ', math.max(0, win_width - used))
          if pad ~= '' then table.insert(parts, { pad, 'DiffDelete' }) end
        else
          local pad = string.rep(' ', math.max(0, win_width - vim.fn.strdisplaywidth(text)))
          if pad ~= '' then table.insert(parts, { pad, 'DiffDelete' }) end
        end
        table.insert(virt_lines, parts)
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns_id, anchor, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        id = 3000 + i * 100,
      })
    end

    -- Add sign in gutter for hunk (use first addition or deletion line)
    local sign_line = nil
    if #additions > 0 then
      sign_line = additions[1]
    elseif #deletions > 0 then
      sign_line = deletions[1].line
    else
      sign_line = hunk.new_start - 1
    end

    -- Determine sign style based on hunk content
    local sign_text = '+'
    local sign_hl = 'DiffAdd'
    if #additions > 0 and #deletions > 0 then
      sign_text = '±'
      sign_hl = 'DiffText'
    elseif #additions == 0 and #deletions > 0 then
      sign_text = '~'
      sign_hl = 'DiffChange'
    end

    if sign_line and sign_line >= 0 and sign_line < #buf_lines then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, sign_line, 0, {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
        id = 2000 + i,
      })
    end

    -- Add subtle hunk info at end of first changed line (only for hunks with additions)
    if #additions > 0 then
      local info_line = sign_line
      if info_line and info_line >= 0 and info_line < #buf_lines then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, info_line, 0, {
          virt_text = { { ' [Hunk ' .. i .. '/' .. #diff_data.hunks .. ']', 'Comment' } },
          virt_text_pos = 'eol',
          id = 1000 + i,
        })
      end
    end
  end
end

return M
