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
local executor = require('nvim-claude.inline_diff.executor')
local project_state = require('nvim-claude.project-state')
local review_state = require('nvim-claude.review_state')

local state_file = '/tmp/nvim-claude-inline-test-state-' .. vim.fn.getpid() .. '.json'
project_state.get_state_file = function() return state_file end

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

local function wipe_root_buffers(root)
  local resolved_root = vim.fn.resolve(root)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))
    if name:sub(1, #resolved_root + 1) == resolved_root .. '/' then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

describe('inline_diff.hunks action plans', function()
  local root
  local original_cwd = vim.fn.getcwd()
  before_each(function()
    vim.fn.delete(state_file)
    if project_state.clear_cache then project_state.clear_cache() end
    root = tmpdir()
    vim.fn.chdir(root)
    init_repo(root)
  end)

  after_each(function()
    if root then wipe_root_buffers(root) end
    vim.fn.chdir(original_cwd)
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

describe('inline_diff executed regressions', function()
  local root
  local original_cwd = vim.fn.getcwd()

  before_each(function()
    vim.fn.delete(state_file)
    if project_state.clear_cache then project_state.clear_cache() end
    root = tmpdir()
    vim.fn.chdir(root)
    init_repo(root)
  end)

  after_each(function()
    if root then wipe_root_buffers(root) end
    vim.fn.chdir(original_cwd)
    if root then vim.fn.delete(root, 'rf') end
  end)

  it('computes unified hunks without filesystem or shell helpers', function()
    local original_exec = utils.exec
    local original_write = utils.write_file
    utils.exec = function() error('unexpected shell call') end
    utils.write_file = function() error('unexpected file write') end
    local ok, result = pcall(inline.compute_diff, 'a\nb\nc\nd\ne\n', 'A\nb\nc\nd\nE\n')
    utils.exec = original_exec
    utils.write_file = original_write

    truthy(ok)
    eq(2, #result.hunks)
    for _, hunk in ipairs(result.hunks) do
      assert.is_number(hunk.old_start)
      assert.is_number(hunk.old_count)
      assert.is_number(hunk.new_start)
      assert.is_number(hunk.new_count)
      assert.is_table(hunk.lines)
      assert.is_string(hunk.header)
    end
  end)

  it('treats baseline messages as data', function()
    local path = root .. '/file.txt'
    local marker = root .. '/injected'
    write_lines(path, { 'content' })
    git('git add . && git commit -m init', root)

    truthy(baseline.create_baseline('$(touch ' .. marker .. ')', root) ~= nil)
    falsy(vim.loop.fs_stat(marker) ~= nil)
  end)

  it('rejects the hunk selected through the public navigation facade', function()
    local path = root .. '/selected.txt'
    local initial = {}
    for i = 1, 30 do initial[i] = 'line ' .. i end
    write_lines(path, initial)
    git('git add . && git commit -m init', root)
    baseline.create_baseline('baseline test', root)

    local modified = vim.deepcopy(initial)
    modified[5] = 'changed five'
    modified[25] = 'changed twenty-five'
    write_lines(path, modified)
    local bufnr = open_buf(path)
    review_state.add_edited_file(root, 'selected.txt')
    inline.refresh_inline_diff(bufnr)
    eq(2, #inline.get_diff_state(bufnr).hunks)

    inline.jump_to_hunk(bufnr, 2, true)
    eq(2, inline.get_diff_state(bufnr).current_hunk)
    inline.reject_current_hunk(bufnr)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    eq('changed five', lines[5])
    eq('line 25', lines[25])
    eq(1, #inline.get_diff_state(bufnr).hunks)
    truthy(review_state.is_edited_file(root, 'selected.txt'))
  end)

  it('stops before untracking when a baseline update fails', function()
    local path = root .. '/failure.txt'
    write_lines(path, { 'before' })
    git('git add . && git commit -m init', root)
    local ref = baseline.create_baseline('baseline test', root)
    write_lines(path, { 'after' })
    local bufnr = open_buf(path)
    review_state.add_edited_file(root, 'failure.txt')
    inline.refresh_inline_diff(bufnr)

    local original_update = baseline.update_baseline_with_content
    local original_notify = vim.notify
    baseline.update_baseline_with_content = function() return false, 'forced failure' end
    vim.notify = function() end
    local ok, err = pcall(inline.accept_current_hunk, bufnr)
    baseline.update_baseline_with_content = original_update
    vim.notify = original_notify

    truthy(ok, err)
    eq(ref, baseline.get_baseline_ref(root))
    truthy(review_state.is_edited_file(root, 'failure.txt'))
    truthy(inline.has_active_diff(bufnr))
  end)

  it('returns a failure and skips later actions', function()
    review_state.add_edited_file(root, 'tracked.txt')
    local result = executor.run_actions({
      { type = 'unknown_effect' },
      { type = 'project_untrack_file', git_root = root, relative_path = 'tracked.txt' },
    })
    falsy(result.ok)
    eq(0, result.completed)
    truthy(review_state.is_edited_file(root, 'tracked.txt'))
  end)

  it('normalizes nested absolute paths at the review-state boundary', function()
    local path = root .. '/nested/new.txt'
    vim.fn.mkdir(root .. '/nested', 'p')
    write_lines(path, { 'new' })

    truthy(review_state.add_edited_file(root, path))
    eq('nested/new.txt', review_state.list_edited_files(root)[1])
    truthy(review_state.is_edited_file(root, path))
    truthy(review_state.remove_edited_file(root, path))
    falsy(review_state.is_edited_file(root, 'nested/new.txt'))
  end)

  it('globally rejects into loaded buffers without allowing resurrection', function()
    local path = root .. '/loaded.txt'
    write_lines(path, { 'before' })
    git('git add . && git commit -m init', root)
    baseline.create_baseline('baseline test', root)
    write_lines(path, { 'after' })
    local bufnr = open_buf(path)
    review_state.add_edited_file(root, 'loaded.txt')
    inline.refresh_inline_diff(bufnr)

    truthy(inline.reject_all_files())
    eq('before', table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n'))
    eq('before', table.concat(vim.fn.readfile(path), '\n'))
    falsy(vim.bo[bufnr].modified)
    falsy(review_state.is_edited_file(root, 'loaded.txt'))
    falsy(inline.has_active_diff(bufnr))

    vim.api.nvim_buf_call(bufnr, function() vim.cmd 'write' end)
    eq('before', table.concat(vim.fn.readfile(path), '\n'))
  end)

  it('accepts all files with one batched baseline commit', function()
    local path_a = root .. '/a.txt'
    local path_b = root .. '/b.txt'
    write_lines(path_a, { 'a0' })
    write_lines(path_b, { 'b0' })
    git('git add . && git commit -m init', root)
    local old_ref = baseline.create_baseline('baseline test', root)
    write_lines(path_a, { 'a1' })
    write_lines(path_b, { 'b1' })
    open_buf(path_a)
    review_state.add_edited_file(root, 'a.txt')
    review_state.add_edited_file(root, 'b.txt')

    truthy(inline.accept_all_files())
    local new_ref = baseline.get_baseline_ref(root)
    eq('1\n', git('git rev-list --count ' .. new_ref .. ' ^' .. old_ref, root))
    eq('a1\n', git('git show ' .. new_ref .. ':a.txt', root))
    eq('b1\n', git('git show ' .. new_ref .. ':b.txt', root))
    falsy(review_state.is_edited_file(root, 'a.txt'))
    falsy(review_state.is_edited_file(root, 'b.txt'))
  end)

  it('globally rejects and closes a loaded file absent from the baseline', function()
    git('git commit --allow-empty -m init', root)
    baseline.create_baseline('baseline test', root)
    local path = root .. '/new.txt'
    write_lines(path, { 'new content' })
    local bufnr = open_buf(path)
    review_state.add_edited_file(root, 'new.txt')
    inline.refresh_inline_diff(bufnr)

    truthy(inline.reject_all_files())
    falsy(vim.api.nvim_buf_is_valid(bufnr))
    falsy(vim.loop.fs_stat(path) ~= nil)
    falsy(review_state.is_edited_file(root, 'new.txt'))
    falsy(inline.has_active_diff(bufnr))
  end)

  it('restores an existing empty file instead of deleting it', function()
    local path = root .. '/empty.txt'
    truthy(utils.write_file(path, ''))
    git('git add . && git commit -m init', root)
    baseline.create_baseline('baseline test', root)
    write_lines(path, { 'not empty' })
    local bufnr = open_buf(path)
    review_state.add_edited_file(root, 'empty.txt')
    inline.refresh_inline_diff(bufnr)

    truthy(inline.reject_all_files())
    truthy(vim.loop.fs_stat(path) ~= nil)
    eq('', utils.read_file(path))
    truthy(vim.api.nvim_buf_is_valid(bufnr))
    eq('', table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n'))
  end)

  it('accepts truncation as an empty baseline blob without closing the buffer', function()
    local path = root .. '/truncate.txt'
    write_lines(path, { 'content' })
    git('git add . && git commit -m init', root)
    baseline.create_baseline('baseline test', root)
    truthy(utils.write_file(path, ''))
    local bufnr = open_buf(path)
    review_state.add_edited_file(root, 'truncate.txt')
    inline.refresh_inline_diff(bufnr)
    eq(0, inline.get_diff_state(bufnr).hunks[1].new_start)
    local jumped, jump_err = pcall(inline.jump_to_hunk, bufnr, 1, true)
    truthy(jumped, jump_err)

    inline.accept_all_hunks(bufnr)
    local ref = baseline.get_baseline_ref(root)
    git('git cat-file -e ' .. ref .. ':truncate.txt', root)
    eq(0, vim.v.shell_error)
    eq('', git('git show ' .. ref .. ':truncate.txt', root))
    truthy(vim.api.nvim_buf_is_valid(bufnr))
    falsy(review_state.is_edited_file(root, 'truncate.txt'))
  end)

  it('clears active diff state when a buffer is deleted', function()
    local path = root .. '/delete-buffer.txt'
    write_lines(path, { 'before' })
    git('git add . && git commit -m init', root)
    baseline.create_baseline('baseline test', root)
    write_lines(path, { 'after' })
    local bufnr = open_buf(path)
    inline.refresh_inline_diff(bufnr)
    truthy(inline.has_active_diff(bufnr))

    vim.api.nvim_buf_delete(bufnr, { force = true })
    falsy(inline.has_active_diff(bufnr))
  end)
end)
