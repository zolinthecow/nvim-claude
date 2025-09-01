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

  -- Get current buffer lines for reference
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Apply highlights for each hunk
  for i, hunk in ipairs(diff_data.hunks) do
    -- Track which lines in the current buffer correspond to additions/deletions
    local additions = {}
    local deletions = {}

    -- Start from the beginning of the hunk and track line numbers
    local new_line_num = hunk.new_start -- 1-indexed line number in new file
    local old_line_num = hunk.old_start -- 1-indexed line number in old file

    -- First, detect if this hunk is a replacement (has both - and + lines)
    local has_deletions = false
    local has_additions = false
    for _, diff_line in ipairs(hunk.lines or {}) do
      if diff_line:match '^%-' then
        has_deletions = true
      end
      if diff_line:match '^%+' then
        has_additions = true
      end
    end
    local is_replacement = has_deletions and has_additions

    for _, diff_line in ipairs(hunk.lines or {}) do
      if diff_line:match '^%+' then
        -- This is an added line - it exists in the current buffer at new_line_num
        table.insert(additions, new_line_num - 1) -- Convert to 0-indexed for extmarks
        new_line_num = new_line_num + 1
        -- Don't advance old_line_num for additions
      elseif diff_line:match '^%-' then
        -- This is a deleted line - show as virtual text above current position
        -- For replacements, the deletion should appear above the addition
        local del_line = new_line_num - 1
        if is_replacement and #additions > 0 then
          -- Place deletion above the first addition
          del_line = additions[1]
        end
        table.insert(deletions, {
          line = del_line, -- 0-indexed
          text = diff_line:sub(2),
        })
        old_line_num = old_line_num + 1
        -- Don't advance new_line_num for deletions
      elseif diff_line:match '^%s' then
        -- Context line - advance both
        new_line_num = new_line_num + 1
        old_line_num = old_line_num + 1
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

    -- Show deletions as virtual text above their position with full-width background
    for j, del in ipairs(deletions) do
      -- Determine if this is an EOF deletion
      local is_eof_deletion = del.line >= #buf_lines
      local placement_line = is_eof_deletion and (#buf_lines - 1) or del.line

      if placement_line >= 0 and placement_line < #buf_lines then
        -- Calculate full width for the deletion line
        local text = '- ' .. del.text
        local win_width = vim.api.nvim_win_get_width(0)

        -- For deletion-only hunks, add hunk info to the first deletion
        local hunk_indicator = ''
        if j == 1 and #additions == 0 then
          -- This is a deletion-only hunk, add the hunk indicator
          hunk_indicator = ' [Hunk ' .. i .. '/' .. #diff_data.hunks .. ']'
        end

        -- Build virtual line parts
        local virt_line_parts = {}
        if hunk_indicator ~= '' then
          -- Structure: deletion text + hunk indicator + padding to fill the rest
          table.insert(virt_line_parts, { text, 'DiffDelete' })
          table.insert(virt_line_parts, { hunk_indicator, 'Comment' })

          -- Calculate remaining width and fill with red background
          local used_width = vim.fn.strdisplaywidth(text) + vim.fn.strdisplaywidth(hunk_indicator)
          local remaining_width = win_width - used_width
          if remaining_width > 0 then
            local padding = string.rep(' ', remaining_width)
            table.insert(virt_line_parts, { padding, 'DiffDelete' })
          end
        else
          -- Normal deletion line - keep full width for visibility
          local padding = string.rep(' ', math.max(0, win_width - vim.fn.strdisplaywidth(text)))
          table.insert(virt_line_parts, { text .. padding, 'DiffDelete' })
        end

        vim.api.nvim_buf_set_extmark(bufnr, ns_id, placement_line, 0, {
          virt_lines = { virt_line_parts },
          virt_lines_above = not is_eof_deletion, -- EOF deletions appear below the last line
          id = 3000 + i * 100 + j,
        })
      end
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

