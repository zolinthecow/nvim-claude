local M = {}

local function split_lines_preserve(content)
  local text = content or ''
  local lines = vim.split(text, '\n', { plain = true, trimempty = false })

  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines, #lines)
  end

  if #lines == 1 and lines[1] == '' and text == '' then
    lines = {}
  end

  return lines
end

local function join_lines(lines)
  return table.concat(lines, '\n')
end

local function copy_lines(lines)
  local out = {}
  for i = 1, #lines do
    out[i] = lines[i]
  end
  return out
end

local function slice_lines(lines, start_idx, end_idx)
  local start = start_idx or 1
  local stop = end_idx or #lines
  local out = {}
  if stop < start then
    return out
  end
  for i = start, math.min(stop, #lines) do
    out[#out + 1] = lines[i]
  end
  return out
end

local function rstrip(text)
  return (text or ''):gsub('%s+$', '')
end

local function normalize_unicode_characters()
  local map = {}
  local function add(codepoints, replacement)
    for _, cp in ipairs(codepoints) do
      map[vim.fn.nr2char(cp)] = replacement
    end
  end

  add({ 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 }, '-')
  add({ 0x2018, 0x2019, 0x201A, 0x201B }, "'")
  add({ 0x201C, 0x201D, 0x201E, 0x201F }, '"')
  add({ 0x00A0, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 }, ' ')

  return map
end

local unicode_map = normalize_unicode_characters()

local function normalize_for_match(text)
  local trimmed = vim.trim(text or '')
  if trimmed == '' then
    return ''
  end

  local chars = vim.fn.split(trimmed, '\\zs')
  for idx, ch in ipairs(chars) do
    local mapped = unicode_map[ch]
    if mapped then
      chars[idx] = mapped
    end
  end
  return table.concat(chars, '')
end

local function seek_sequence(lines, pattern, start_idx, eof)
  local pattern_len = #pattern
  if pattern_len == 0 then
    return math.max(start_idx or 1, 1)
  end

  if pattern_len > #lines then
    return nil
  end

  local search_start = math.max(start_idx or 1, 1)
  if eof and #lines >= pattern_len then
    search_start = #lines - pattern_len + 1
  end
  local max_start = #lines - pattern_len + 1
  if search_start > max_start then
    search_start = max_start
  end

  local function matches_at(idx, comparator)
    for offset = 1, pattern_len do
      if not comparator(lines[idx + offset - 1], pattern[offset]) then
        return false
      end
    end
    return true
  end

  local function exact(a, b)
    return a == b
  end

  for i = search_start, max_start do
    if matches_at(i, exact) then
      return i
    end
  end

  local function trimmed_end(a, b)
    return rstrip(a) == rstrip(b)
  end

  for i = search_start, max_start do
    if matches_at(i, trimmed_end) then
      return i
    end
  end

  local function trimmed(a, b)
    return vim.trim(a or '') == vim.trim(b or '')
  end

  for i = search_start, max_start do
    if matches_at(i, trimmed) then
      return i
    end
  end

  local function normalized(a, b)
    return normalize_for_match(a) == normalize_for_match(b)
  end

  for i = search_start, max_start do
    if matches_at(i, normalized) then
      return i
    end
  end

  return nil
end

local function normalize_diff_line(line)
  if line == '' then
    return ' '
  end
  if line:match('^@@') or line:match('^%*%*%* End of File') then
    return line
  end
  local prefix = line:sub(1, 1)
  if prefix == '+' or prefix == '-' or prefix == ' ' then
    return line
  end
  return ' ' .. line
end

local function new_chunk(context)
  return {
    change_context = context,
    old_lines = {},
    new_lines = {},
    is_end_of_file = false,
  }
end

local function parse_update_hunks(lines)
  local hunks = {}
  local current = nil

  local function push_chunk()
    if current and (#current.old_lines > 0 or #current.new_lines > 0) then
      table.insert(hunks, current)
    end
    current = nil
  end

  for _, raw_line in ipairs(lines or {}) do
    local line = normalize_diff_line(raw_line)
    if line:match('^@@') then
      push_chunk()
      if line == '@@' then
        current = new_chunk(nil)
      elseif line:sub(1, 3) == '@@ ' then
        current = new_chunk(line:sub(4))
      else
        current = new_chunk(line:sub(3))
      end
    elseif line:match('^%*%*%*%s+End of File') then
      if not current then
        current = new_chunk(nil)
      end
      current.is_end_of_file = true
      push_chunk()
    else
      if not current then
        current = new_chunk(nil)
      end
      local prefix = line:sub(1, 1)
      local text = line
      if prefix == '+' or prefix == '-' or prefix == ' ' then
        text = line:sub(2)
      end
      if prefix == '+' then
        table.insert(current.new_lines, text)
      elseif prefix == '-' then
        table.insert(current.old_lines, text)
      else
        table.insert(current.old_lines, text)
        table.insert(current.new_lines, text)
      end
    end
  end

  push_chunk()
  return hunks
end

function M.parse_apply_patch_operations(patch)
  if type(patch) ~= 'string' or patch == '' then
    return {}, 'empty patch payload'
  end

  local lines = vim.split(patch, '\n', { plain = true })
  local idx = 1
  while idx <= #lines and lines[idx]:match('^%s*$') do
    idx = idx + 1
  end
  if idx > #lines or lines[idx] ~= '*** Begin Patch' then
    return nil, 'missing *** Begin Patch header'
  end
  idx = idx + 1

  local operations = {}
  local current = nil

  local function push_current()
    if current then
      if current.type == 'update' then
        current.hunks = parse_update_hunks(current.lines)
      end
      table.insert(operations, current)
    end
    current = nil
  end

  while idx <= #lines do
    local line = lines[idx]
    if line == '*** End Patch' then
      push_current()
      break
    end

    local add = line:match('^%*%*%*%s+Add File:%s+(.+)$')
    local update = line:match('^%*%*%*%s+Update File:%s+(.+)$')
    local delete = line:match('^%*%*%*%s+Delete File:%s+(.+)$')
    local move_to = line:match('^%*%*%*%s+Move to:%s+(.+)$')

    if add or update or delete then
      push_current()
      if add then
        current = { type = 'add', path = vim.trim(add), lines = {} }
      elseif update then
        current = { type = 'update', path = vim.trim(update), lines = {} }
      else
        current = { type = 'delete', path = vim.trim(delete) }
      end
    elseif move_to and current and current.type == 'update' then
      current.move_path = vim.trim(move_to)
    elseif current and current.type ~= 'delete' then
      current.lines = current.lines or {}
      table.insert(current.lines, normalize_diff_line(line))
    end

    idx = idx + 1
  end

  return operations
end

local function compute_reverse_replacements(lines, hunks)
  local replacements = {}
  local line_index = 1

  for _, hunk in ipairs(hunks or {}) do
    local ctx = hunk.change_context
    if ctx and ctx ~= '' then
      local ctx_idx = seek_sequence(lines, { ctx }, line_index, false)
      if not ctx_idx then
        return nil, string.format("failed to locate context '%s'", ctx)
      end
      line_index = ctx_idx + 1
    end

    local pattern = hunk.new_lines or {}
    local replacement = hunk.old_lines or {}

    if #pattern == 0 then
      local insertion_idx
      if hunk.is_end_of_file then
        insertion_idx = #lines + 1
      else
        insertion_idx = math.max(1, line_index)
      end
      insertion_idx = math.min(insertion_idx, #lines + 1)
      table.insert(replacements, { insertion_idx, 0, copy_lines(replacement) })
      line_index = insertion_idx + #replacement
    else
      local search_slice = pattern
      local replace_slice = replacement
      local start_idx = seek_sequence(lines, search_slice, line_index, hunk.is_end_of_file)

      if not start_idx and search_slice[#search_slice] == '' then
        search_slice = slice_lines(search_slice, 1, #search_slice - 1)
        if replace_slice[#replace_slice] == '' then
          replace_slice = slice_lines(replace_slice, 1, #replace_slice - 1)
        end
        start_idx = seek_sequence(lines, search_slice, line_index, hunk.is_end_of_file)
      end

      if not start_idx then
        return nil, 'failed to locate expected lines for reverse chunk'
      end

      table.insert(replacements, { start_idx, #search_slice, copy_lines(replace_slice) })
      line_index = start_idx + #search_slice
    end
  end

  table.sort(replacements, function(a, b)
    return a[1] < b[1]
  end)

  return replacements
end

local function apply_replacements(lines, replacements)
  local result = copy_lines(lines)
  for idx = #replacements, 1, -1 do
    local replacement = replacements[idx]
    local start_idx = replacement[1]
    local old_len = replacement[2]
    local new_segment = replacement[3] or {}

    for _ = 1, old_len do
      if start_idx <= #result then
        table.remove(result, start_idx)
      end
    end

    for offset, text in ipairs(new_segment) do
      table.insert(result, start_idx + offset - 1, text)
    end
  end
  return result
end

function M.reconstruct_prior_content(current_content, hunks)
  if type(current_content) ~= 'string' then
    return nil, 'current file contents missing'
  end
  if not hunks or #hunks == 0 then
    return nil, 'no diff hunks to replay'
  end

  local new_lines = split_lines_preserve(current_content)
  local replacements, err = compute_reverse_replacements(new_lines, hunks)
  if not replacements then
    return nil, err
  end
  local restored = apply_replacements(new_lines, replacements)
  if restored[#restored] ~= '' then
    restored[#restored + 1] = ''
  end
  return join_lines(restored)
end

return M
