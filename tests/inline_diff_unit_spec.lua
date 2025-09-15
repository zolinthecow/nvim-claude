local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local utils = require('nvim-claude.utils')
-- Stub logger to avoid writing to restricted locations during tests
do
  local logger = require('nvim-claude.logger')
  logger.get_log_file = function()
    local dir = '/tmp/nvim-claude-test-logs'
    vim.fn.mkdir(dir, 'p')
    return dir .. '/debug.log'
  end
  logger.get_mcp_debug_log_file = function()
    return '/tmp/nvim-claude-mcp-debug.log'
  end
  logger.get_stop_hook_log_file = function()
    return '/tmp/stop-hook-debug.log'
  end
end
local baseline = require('nvim-claude.inline_diff.baseline')
local inline = require('nvim-claude.inline_diff')
local hunks = require('nvim-claude.inline_diff.hunks')

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.delete(dir, 'rf')
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function write_lines(path, lines)
  vim.fn.writefile(lines, path)
end

local function git(cmd, cwd)
  cwd = cwd or vim.loop.cwd()
  local full = string.format("cd '%s' && %s 2>&1", cwd, cmd)
  return vim.fn.system(full)
end

local function init_repo(root)
  git('git init -q', root)
  git('git config user.email test@example.com', root)
  git('git config user.name test', root)
end

local function open_buf(path)
  vim.cmd('edit ' .. path)
  return vim.fn.bufnr(path)
end

describe('inline_diff.hunks action plans', function()
  local root
  before_each(function()
    root = tmpdir()
    vim.fn.chdir(root)
    init_repo(root)
  end)

  after_each(function()
    if root then vim.fn.delete(root, 'rf') end
  end)

  it('accept_current_hunk returns baseline_update_file and untracks when last hunk', function()
    -- Create initial file and commit
    local path = root .. '/file.txt'
    local initial = {}
    for i=1,30 do initial[i] = ('line %d'):format(i) end
    write_lines(path, initial)
    git('git add .', root)
    git('git commit -m init', root)

    -- Create baseline snapshot
    local ref = baseline.create_baseline('baseline test')
    assert.is_string(ref)

    -- Modify file to create a single hunk
    local mod = vim.deepcopy(initial)
    mod[10] = 'MODIFIED line 10'
    table.insert(mod, 11, 'ADDED line after 10')
    write_lines(path, mod)

    local bufnr = open_buf(path)
    inline.refresh_inline_diff(bufnr)
    local state = inline.get_diff_state(bufnr)
    assert.truthy(state and #state.hunks >= 1)

    -- Accept the only hunk; plan should include baseline update + untrack
    local plan = hunks.accept_current_hunk(bufnr)
    eq('ok', plan.status)
    truthy(#plan.actions >= 1)
    eq('baseline_update_file', plan.actions[1].type)
    -- If only one hunk, accepting it should clear diffs and include untrack
    local has_untrack = false
    for _, a in ipairs(plan.actions) do if a.type == 'project_untrack_file' then has_untrack = true end end
    truthy(has_untrack)
  end)

  it('reject_current_hunk returns buffer edits for existing files', function()
    local path = root .. '/file.txt'
    local initial = {}
    for i=1,20 do initial[i] = ('line %d'):format(i) end
    write_lines(path, initial)
    git('git add .', root)
    git('git commit -m init', root)
    baseline.create_baseline('baseline test')

    -- Modify: one hunk
    local mod = vim.deepcopy(initial)
    mod[5] = 'MODIFIED line 5'
    write_lines(path, mod)
    local bufnr = open_buf(path)
    inline.refresh_inline_diff(bufnr)
    local state = inline.get_diff_state(bufnr)
    assert.truthy(state and #state.hunks >= 1)

    local plan = hunks.reject_current_hunk(bufnr)
    eq('ok', plan.status)
    -- Should plan to set buffer content and write
    local seen_set, seen_write = false, false
    for _, a in ipairs(plan.actions) do
      if a.type == 'buffer_set_content' then seen_set = true end
      if a.type == 'buffer_write' then seen_write = true end
    end
    truthy(seen_set)
    truthy(seen_write)
  end)

  it('reject_current_hunk deletes and untracks new files', function()
    baseline.create_baseline('baseline test')
    -- Create a new file (not in baseline)
    local path = root .. '/new.txt'
    write_lines(path, { 'new line 1', 'new line 2' })
    local bufnr = open_buf(path)

    -- Diff vs empty baseline
    inline.refresh_inline_diff(bufnr)
    local state = inline.get_diff_state(bufnr)
    assert.truthy(state and #state.hunks >= 1)

    local plan = hunks.reject_current_hunk(bufnr)
    eq('ok', plan.status)
    local have_delete, have_close, have_untrack = false, false, false
    for _, a in ipairs(plan.actions) do
      if a.type == 'file_delete' then have_delete = true end
      if a.type == 'buffer_close' then have_close = true end
      if a.type == 'project_untrack_file' then have_untrack = true end
    end
    truthy(have_delete)
    truthy(have_close)
    truthy(have_untrack)
  end)

  it('accept_all_hunks_in_file returns baseline update and untrack', function()
    local path = root .. '/file.txt'
    write_lines(path, { 'a', 'b', 'c' })
    git('git add .', root)
    git('git commit -m init', root)
    baseline.create_baseline('baseline test')

    -- Modify entire content
    write_lines(path, { 'x', 'y', 'z' })
    local bufnr = open_buf(path)

    local plan = hunks.accept_all_hunks_in_file(bufnr)
    eq('ok', plan.status)
    eq('baseline_update_file', plan.actions[1].type)
    -- Expect untrack action as well
    local has_untrack = false
    for _, a in ipairs(plan.actions) do if a.type == 'project_untrack_file' then has_untrack = true end end
    truthy(has_untrack)
  end)

  it('reject_all_hunks_in_file restores buffer to baseline and untracks', function()
    local path = root .. '/file.txt'
    write_lines(path, { 'a', 'b', 'c' })
    git('git add .', root)
    git('git commit -m init', root)
    baseline.create_baseline('baseline test')
    write_lines(path, { 'aX', 'b', 'c' })
    local bufnr = open_buf(path)

    local plan = hunks.reject_all_hunks_in_file(bufnr)
    eq('ok', plan.status)
    local have_set, have_write, have_untrack = false, false, false
    for _, a in ipairs(plan.actions) do
      if a.type == 'buffer_set_content' then have_set = true end
      if a.type == 'buffer_write' then have_write = true end
      if a.type == 'project_untrack_file' then have_untrack = true end
    end
    truthy(have_set)
    truthy(have_write)
    truthy(have_untrack)
  end)

  it('batch accept/reject across all files returns aggregated actions', function()
    -- Setup repo with two files and baseline
    local p1 = root .. '/f1.txt'
    local p2 = root .. '/f2.txt'
    write_lines(p1, { '1', '2', '3' })
    write_lines(p2, { 'a', 'b', 'c' })
    git('git add .', root)
    git('git commit -m init', root)
    baseline.create_baseline('baseline test')

    -- Modify both files
    write_lines(p1, { '1', '2X', '3' })
    write_lines(p2, { 'a', 'b', 'cX' })
    local b1 = open_buf(p1)
    local b2 = open_buf(p2)

    inline.refresh_inline_diff(b1)
    inline.refresh_inline_diff(b2)
    local active = {}
    active[b1] = inline.get_diff_state(b1)
    active[b2] = inline.get_diff_state(b2)

    local planA = hunks.accept_all_hunks_in_all_files(active)
    eq('ok', planA.status)
    truthy(#planA.actions >= 2)

    local planR = hunks.reject_all_hunks_in_all_files(active)
    eq('ok', planR.status)
    truthy(#planR.actions >= 2)
  end)
end)
