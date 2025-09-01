-- Inline diff utilities: computing and parsing diffs

local M = {}

local utils = require 'nvim-claude.utils'

-- Ensure consistent newline endings to avoid phantom diffs
local function normalize(text)
  text = text or ''
  if text ~= '' and not text:match '\n$' then
    text = text .. '\n'
  end
  return text
end

-- Parse unified diff output into hunk structures
local function parse_diff(diff_text)
  local hunks = {}
  ---@type table|nil
  local current_hunk = nil

  for line in (diff_text or ''):gmatch '[^\r\n]+' do
    if line:match '^@@' then
      -- New hunk header
      if current_hunk then
        table.insert(hunks, current_hunk)
      end

      local old_start, old_count, new_start, new_count = line:match '^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@'
      current_hunk = {
        old_start = tonumber(old_start),
        old_count = tonumber(old_count) or 1,
        new_start = tonumber(new_start),
        new_count = tonumber(new_count) or 1,
        lines = {},
        header = line,
      }
    elseif current_hunk and (line:match '^[%+%-]' or line:match '^%s') then
      -- Diff line
      current_hunk.lines = current_hunk.lines or {}
      table.insert(current_hunk.lines, line)
    elseif line:match '^diff %-%-git' or line:match '^index ' or line:match '^%+%+%+ ' or line:match '^%-%-%-' then
      -- Skip git diff headers
      current_hunk = nil
    end
  end

  -- Add last hunk
  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

-- Compute diff hunks between two texts
function M.compute_diff(old_text, new_text)
  old_text = normalize(old_text)
  new_text = normalize(new_text)

  -- Write texts to temp files
  local old_file = '/tmp/nvim-claude-old.txt'
  local new_file = '/tmp/nvim-claude-new.txt'

  utils.write_file(old_file, old_text)
  utils.write_file(new_file, new_text)

  -- Use git diff with histogram algorithm for better code diffs
  local cmd = string.format('git diff --no-index --no-prefix --unified=1 --diff-algorithm=histogram "%s" "%s" 2>/dev/null || true', old_file, new_file)
  local diff_output = utils.exec(cmd)

  local hunks = parse_diff(diff_output or '')
  return { hunks = hunks }
end

return M
