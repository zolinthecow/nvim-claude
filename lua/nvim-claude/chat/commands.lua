-- Chat-related user commands (tmux-driven)

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

local function ensure_pane(tmux)
  local pane = tmux.find_claude_pane()
  if not pane then pane = tmux.create_pane('claude') end
  return pane
end

local function format_diagnostics_list(diags)
  if not diags or #diags == 0 then return 'No diagnostics in selected range' end
  local lines = {}
  for _, d in ipairs(diags) do
    local sev = vim.diagnostic.severity[d.severity]
    table.insert(lines, string.format('- Line %d, Col %d [%s]: %s', (d.lnum or 0) + 1, (d.col or 0) + 1, sev, d.message or ''))
  end
  return table.concat(lines, '\n')
end

function M.register(claude)
  local utils = require('nvim-claude.utils')
  local tmux = utils.tmux

  -- ClaudeChat: open pane
  define('ClaudeChat', function()
    if not tmux.validate() then return end
    local pane_id = tmux.create_pane('claude')
    if pane_id then vim.notify('Claude chat opened in pane ' .. pane_id, vim.log.levels.INFO)
    else vim.notify('Failed to create Claude pane', vim.log.levels.ERROR) end
  end, { desc = 'Open Claude in a tmux pane' })

  -- ClaudeSendBuffer: send whole buffer
  define('ClaudeSendBuffer', function()
    if not tmux.validate() then return end
    local pane = ensure_pane(tmux)
    if not pane then vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR); return end
    local filename = vim.fn.expand('%:t')
    local filetype = vim.bo.filetype
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local parts = { string.format('Here is `%s` (%s):', filename, filetype), '```' .. (filetype ~= '' and filetype or '') }
    for _, l in ipairs(lines) do table.insert(parts, l) end
    table.insert(parts, '```')
    tmux.send_text_to_pane(pane, table.concat(parts, '\n'))
    vim.notify('Buffer sent to Claude', vim.log.levels.INFO)
  end, { desc = 'Send current buffer to Claude' })

  -- ClaudeSendSelection: send selected range
  define('ClaudeSendSelection', function(args)
    if not tmux.validate() then return end
    local pane = ensure_pane(tmux)
    if not pane then vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR); return end
    local l1, l2 = args.line1, args.line2
    local sel = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
    local git_root = utils.get_project_root()
    local file_path = vim.fn.expand('%:p')
    local rel = git_root and file_path:gsub('^' .. vim.pesc(git_root) .. '/', '') or vim.fn.expand('%:t')
    local ft = vim.bo.filetype
    local parts = { string.format('Selection from `%s` (lines %d-%d):', rel, l1, l2), '```' .. (ft ~= '' and ft or '') }
    for _, l in ipairs(sel) do table.insert(parts, l) end
    table.insert(parts, '```')
    tmux.send_text_to_pane(pane, table.concat(parts, '\n'))
    utils.exec('tmux select-pane -t ' .. pane)
    vim.notify('Selection sent to Claude', vim.log.levels.INFO)
  end, { desc = 'Send selected text to Claude', range = true })

  -- ClaudeSendWithDiagnostics: selection plus diagnostics
  define('ClaudeSendWithDiagnostics', function(args)
    if not tmux.validate() then return end
    local pane = ensure_pane(tmux)
    if not pane then vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR); return end
    local l1, l2 = args.line1, args.line2
    local sel = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
    local code = table.concat(sel, '\n')
    local git_root = utils.get_project_root()
    local file_path = vim.fn.expand('%:p')
    local file = git_root and file_path:gsub('^' .. vim.pesc(git_root) .. '/', '') or vim.fn.expand('%:t')
    local in_range = {}
    for _, d in ipairs(vim.diagnostic.get(0)) do if d.lnum >= l1 - 1 and d.lnum <= l2 - 1 then table.insert(in_range, d) end end
    local ft = vim.bo.filetype
    local message = string.format([[\nI have a code snippet with LSP diagnostics that need to be fixed:\n\nFile: %s\nLines: %d-%d\n\n```%s\n%s\n```\n\nLSP Diagnostics:\n%s\n\nPlease help me fix these issues.]], file, l1, l2, (ft ~= '' and ft or ''), code, format_diagnostics_list(in_range))
    tmux.send_text_to_pane(pane, message)
    utils.exec('tmux select-pane -t ' .. pane)
    vim.notify('Selection with diagnostics sent to Claude', vim.log.levels.INFO)
  end, { desc = 'Send selected text with diagnostics to Claude', range = true })

  -- ClaudeSendHunk: send git hunk under cursor
  define('ClaudeSendHunk', function()
    if not tmux.validate() then return end
    local pane = ensure_pane(tmux)
    if not pane then vim.notify('Failed to find or create Claude pane', vim.log.levels.ERROR); return end

    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor_pos[1]
    local filename = vim.fn.expand('%:p')
    local relative_filename = vim.fn.expand('%')
    if not filename or filename == '' then vim.notify('No file to get hunk from', vim.log.levels.ERROR); return end

    local diff_output = utils.exec(string.format('git diff HEAD -- %q', filename))
    if not diff_output or diff_output == '' then vim.notify('No git changes found in current file', vim.log.levels.INFO); return end

    local hunk_lines, hunk_start, hunk_end, found = {}, nil, nil, false
    for line in diff_output:gmatch('[^\n]+') do
      if line:match('^@@') then
        local newstart, newcount = line:match('^@@ %-%d+,%d+ %+(%d+),(%d+) @@')
        if newstart and newcount then
          newstart, newcount = tonumber(newstart), tonumber(newcount)
          if current_line >= newstart and current_line < newstart + newcount then
            found = true; hunk_start = newstart; hunk_end = newstart + newcount - 1
            hunk_lines = { line }
          else
            found = false; hunk_lines = {}
          end
        end
      elseif found then
        table.insert(hunk_lines, line)
      end
    end

    if #hunk_lines == 0 then vim.notify('No git hunk found at cursor position', vim.log.levels.INFO); return end
    local parts = { string.format('Git hunk from `%s` (around line %d):', relative_filename, current_line), '```diff' }
    for _, l in ipairs(hunk_lines) do table.insert(parts, l) end
    table.insert(parts, '```')
    tmux.send_text_to_pane(pane, table.concat(parts, '\n'))
    vim.notify('Git hunk sent to Claude', vim.log.levels.INFO)
  end, { desc = 'Send git hunk under cursor to Claude' })
end

return M
