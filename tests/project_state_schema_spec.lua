local eq = assert.are.same
local truthy = assert.truthy

local project_state = require('nvim-claude.project-state')
local inline_diff = require('nvim-claude.inline_diff')
local utils = require('nvim-claude.utils')

-- Stub logger paths for tests.
do
  local logger = require('nvim-claude.logger')
  logger.get_log_file = function()
    local dir = '/tmp/nvim-claude-test-logs'
    vim.fn.mkdir(dir, 'p')
    return dir .. '/debug.log'
  end
end

-- Redirect project-state to a writable temp state file for tests.
do
  local state_dir = '/tmp/nvim-claude-test-state'
  vim.fn.mkdir(state_dir, 'p')
  local state_file = state_dir .. '/state.json'
  project_state.get_state_file = function() return state_file end
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.delete(dir, 'rf')
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function git(cmd, cwd)
  local full = string.format("cd '%s' && %s 2>&1", cwd, cmd)
  return vim.fn.system(full)
end

local function init_repo(root)
  git('git init -q', root)
  git('git config user.email test@example.com', root)
  git('git config user.name test', root)
end

describe('project-state schema normalization', function()
  local root

  before_each(function()
    root = tmpdir()
    vim.fn.chdir(root)
    init_repo(root)
  end)

  after_each(function()
    if root then
      vim.fn.delete(root, 'rf')
    end
    local state_file = project_state.get_state_file()
    if state_file then
      vim.fn.delete(state_file)
    end
  end)

  it('stores claude_edited_files as a map and normalizes paths', function()
    project_state.set(root, 'claude_edited_files', {
      root .. '/a.txt',
      './b.txt',
      'c.txt',
    })

    local edited = project_state.get(root, 'claude_edited_files') or {}
    truthy(edited['a.txt'] == true)
    truthy(edited['b.txt'] == true)
    truthy(edited['c.txt'] == true)

    local raw = utils.read_file(project_state.get_state_file()) or ''
    truthy(raw:match('"claude_edited_files":%b{}') ~= nil)
  end)

  it('uses project-state baseline ref as source of truth (no git-ref fallback)', function()
    local file = root .. '/file.txt'
    vim.fn.writefile({ 'hello' }, file)
    git('git add file.txt', root)
    git('git commit -m init', root)

    local commit = git('git rev-parse HEAD', root):gsub('%s+$', '')
    git(string.format('git update-ref refs/nvim-claude/baseline %s', commit), root)

    project_state.set(root, 'inline_diff_state', nil)
    eq(nil, inline_diff.get_baseline_ref(root))

    project_state.set(root, 'inline_diff_state', {
      baseline_ref = commit,
      timestamp = os.time(),
    })
    eq(commit, inline_diff.get_baseline_ref(root))
  end)

  it('keeps __global keys and drops invalid project keys during normalization', function()
    local state_file = project_state.get_state_file()
    local raw_state = {
      __global = { token = 'keep-me' },
      ['fugitive:/tmp/example/.git'] = { claude_edited_files = { a = true } },
    }
    vim.fn.writefile({ vim.json.encode(raw_state) }, state_file)

    local all = project_state.load_all_states()
    truthy(all.__global ~= nil)
    eq(nil, all['fugitive:/tmp/example/.git'])
  end)
end)
