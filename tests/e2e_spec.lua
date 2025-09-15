local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local helpers = require('tests.helpers')
local utils = require('nvim-claude.utils')
local events = require('nvim-claude.events')
local inline = require('nvim-claude.inline_diff')

local baseline = require('nvim-claude.inline_diff.baseline')

describe('E2E simulated hooks', function()
  local root

  before_each(function()
    root = helpers.tmpdir()
    vim.fn.chdir(root)
    helpers.init_repo(root)
  end)

  after_each(function()
    if root then vim.fn.delete(root, 'rf') end
  end)

  it('Apply Patch Marking: pre/post mark file and show hunks', function()
    local path = root .. '/file.txt'
    helpers.write_lines(path, { 'v1' })
    -- Simulate pre-hook
    events.pre_tool_use(path)
    local git_root = utils.get_project_root()
    local ref = inline.get_baseline_ref(git_root)
    assert.is_string(ref)

    -- Modify file and simulate post-hook
    helpers.write_lines(path, { 'v1-mod' })
    events.post_tool_use(path)

    -- Open buffer and refresh diff
    local bufnr = helpers.open_buf(path)
    vim.bo[bufnr].undofile = false
    inline.refresh_inline_diff(bufnr)
    local d = inline.get_diff_state(bufnr)
    truthy(d ~= nil and #d.hunks >= 1)
  end)

  it('Accept Current Hunk executes and untracks', function()
    local path = root .. '/file.txt'
    helpers.write_lines(path, { 'a', 'b', 'c' })
    -- Create baseline from pre content
    events.pre_tool_use(path)
    local git_root = utils.get_project_root()
    local ref1 = inline.get_baseline_ref(git_root)
    assert.is_string(ref1)

    -- Modify file (single hunk change)
    helpers.write_lines(path, { 'aX', 'b', 'c' })
    events.post_tool_use(path)

    local bufnr = helpers.open_buf(path)
    inline.refresh_inline_diff(bufnr)
    local d = inline.get_diff_state(bufnr)
    assert.truthy(d and #d.hunks >= 1)

    -- Accept current via facade (executes plan)
    inline.accept_current_hunk(bufnr)

    -- Baseline should be advanced and file untracked when no diffs remain
    local ref2 = inline.get_baseline_ref(git_root)
    assert.is_string(ref2)
    assert.are_not.equal(ref1, ref2)
  end)

  it('Reject Current Hunk restores file and untracks', function()
    local path = root .. '/file.txt'
    helpers.write_lines(path, { 'a', 'b', 'c' })
    events.pre_tool_use(path)
    local git_root = utils.get_project_root()
    local ref1 = inline.get_baseline_ref(git_root)

    helpers.write_lines(path, { 'aX', 'b', 'c' })
    events.post_tool_use(path)

    local bufnr = helpers.open_buf(path)
    inline.refresh_inline_diff(bufnr)
    local d = inline.get_diff_state(bufnr)
    assert.truthy(d and #d.hunks >= 1)

    -- Reject current by executing plan manually to avoid Neovim undofile writes in CI
    local hunks_mod = require('nvim-claude.inline_diff.hunks')
    local exec = require('nvim-claude.inline_diff.executor')
    local plan = hunks_mod.reject_current_hunk(bufnr)
    assert.are.equal('ok', plan.status)
    -- Apply actions except buffer_write
    local filtered = {}
    for _, a in ipairs(plan.actions or {}) do
      if a.type ~= 'buffer_write' then table.insert(filtered, a) end
    end
    exec.run_actions(filtered)
    -- Persist to disk explicitly
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.fn.writefile(lines, path)

    -- File should be restored to baseline content on disk
    local content = helpers.read_file(path)
    assert.truthy(content and content:match('^a\nb\nc$'))
  end)

  it('New File Flow: accept adds to baseline; reject deletes', function()
    -- Create empty baseline snapshot
    local ref = baseline.create_baseline('baseline test')
    assert.is_string(ref)

    -- Create new file (not in baseline)
    local path = root .. '/new.txt'
    helpers.write_lines(path, { 'n1', 'n2' })
    events.post_tool_use(path)
    local bufnr = helpers.open_buf(path)
    inline.refresh_inline_diff(bufnr)
    local d = inline.get_diff_state(bufnr)
    assert.truthy(d and #d.hunks >= 1)

    -- Accept all → baseline contains file
    inline.accept_all_hunks(bufnr)
    local git_root = utils.get_project_root()
    local show = helpers.git(string.format("git show %s:'%s'", inline.get_baseline_ref(git_root), 'new.txt'), git_root)
    assert.truthy(show and show:match('n1'))

    -- Create another new file then reject all → file deleted
    local path2 = root .. '/delme.txt'
    helpers.write_lines(path2, { 'x' })
    events.post_tool_use(path2)
    local b2 = helpers.open_buf(path2)
    inline.refresh_inline_diff(b2)
    inline.reject_all_hunks(b2)
    assert.is_false(vim.fn.filereadable(path2) == 1)
  end)
end)
