-- Inline diff utilities: computing and parsing diffs

local M = {}

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

function M.parse_unified_diff(diff_text)
  return parse_diff(diff_text)
end

-- Compute diff hunks between two texts
function M.compute_diff(old_text, new_text, opts)
  opts = opts or {}
  old_text = normalize(old_text)
  new_text = normalize(new_text)

  local ok, diff_output = pcall(vim.diff, old_text, new_text, {
    algorithm = 'histogram',
    ctxlen = 1,
    result_type = 'unified',
  })
  if not ok then
    return nil, tostring(diff_output)
  end

  local hunks = parse_diff(diff_output or '')
  if #hunks == 0 and opts.old_exists ~= nil and opts.new_exists ~= nil and opts.old_exists ~= opts.new_exists then
    hunks = {
      {
        old_start = opts.old_exists and 1 or 0,
        old_count = 0,
        new_start = opts.new_exists and 1 or 0,
        new_count = 0,
        lines = {},
        header = '@@ -0,0 +0,0 @@',
        file_presence = true,
      },
    }
  end

  return { hunks = hunks }
end

return M
