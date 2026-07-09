local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local helpers = require 'tests.helpers'
local project_state = require 'nvim-claude.project-state'
local checkpoint = require 'nvim-claude.checkpoint.core'
require 'nvim-claude.inline_diff'
require 'nvim-claude.review_state'
local registry = require 'nvim-claude.background_agent.registry'
local worktree = require 'nvim-claude.background_agent.worktree'
local creator = require 'nvim-claude.background_agent.create'
local background_config = require 'nvim-claude.background_agent.config'
local background_utils = require 'nvim-claude.utils'
local git = background_utils.git

local function git_output(root, command)
  return helpers.git(command, root):gsub('%s+$', '')
end

local function commit_file(root, path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. path, ':h'), 'p')
  vim.fn.writefile(lines, root .. '/' .. path)
  helpers.git('git add ' .. vim.fn.shellescape(path), root)
  helpers.git("git commit -qm 'initial'", root)
end

describe('checkpoint transactions', function()
  local root
  local state_dir
  local original_cwd

  before_each(function()
    original_cwd = vim.fn.getcwd()
    root = helpers.tmpdir()
    state_dir = helpers.tmpdir()
    helpers.init_repo(root)
    commit_file(root, 'tracked.txt', { 'base' })
    project_state.get_state_file = function() return state_dir .. '/state.json' end
    project_state.clear_cache()
    vim.fn.chdir(root)
  end)

  after_each(function()
    local state = checkpoint.load_state(root)
    if state and state.mode == 'preview' then
      helpers.git('git reset --hard -q', root)
      checkpoint.exit_preview_mode(root)
    end
    vim.fn.chdir(original_cwd)
    vim.fn.delete(root, 'rf')
    vim.fn.delete(state_dir, 'rf')
    project_state.clear_cache()
  end)

  it('restores staged, unstaged, and untracked state exactly', function()
    vim.fn.writefile({ 'staged' }, root .. '/tracked.txt')
    helpers.git('git add tracked.txt', root)
    vim.fn.writefile({ 'staged', 'unstaged' }, root .. '/tracked.txt')
    vim.fn.writefile({ 'untracked' }, root .. '/untracked.txt')

    local status_before = git_output(root, 'git status --short')
    local index_before = git_output(root, 'git diff --cached --binary')
    local worktree_before = git_output(root, 'git diff --binary')
    local checkpoint_id = assert(checkpoint.create_checkpoint('preserve state', root))

    truthy(checkpoint.enter_preview_mode(checkpoint_id, root))
    eq('', git_output(root, 'git status --short'))
    truthy(checkpoint.exit_preview_mode(root))

    eq(status_before, git_output(root, 'git status --short'))
    eq(index_before, git_output(root, 'git diff --cached --binary'))
    eq(worktree_before, git_output(root, 'git diff --binary'))
    eq('', git_output(root, 'git stash list'))
    falsy(checkpoint.load_state(root) ~= nil)
  end)

  it('recovers a stash created before its object id was persisted', function()
    vim.fn.writefile({ 'interrupted' }, root .. '/tracked.txt')
    local original_head = git_output(root, 'git rev-parse HEAD')
    local original_branch = git.current_branch(root)
    local label = 'checkpoint interrupted transaction [test]'
    truthy(checkpoint.save_state({
      mode = 'entering',
      original_branch = original_branch,
      original_head = original_head,
      original_ref = original_branch,
      stash_label = label,
    }, root))
    local stashed = git.stash_push(root, label, true)
    truthy(stashed)
    eq('', git_output(root, 'git status --short'))

    truthy(checkpoint.exit_preview_mode(root))
    eq(' M tracked.txt', git_output(root, 'git status --short'))
    eq('', git_output(root, 'git stash list'))
  end)

  it('retains recovery state when checkout is blocked', function()
    vim.fn.writefile({ 'working' }, root .. '/tracked.txt')
    local checkpoint_id = assert(checkpoint.create_checkpoint('blocked return', root))
    truthy(checkpoint.enter_preview_mode(checkpoint_id, root))

    vim.fn.writefile({ 'preview modification' }, root .. '/tracked.txt')
    falsy(checkpoint.exit_preview_mode(root))
    local state = assert(checkpoint.load_state(root))
    eq('preview', state.mode)
    truthy(type(state.stash_oid) == 'string' and state.stash_oid ~= '')

    helpers.git('git reset --hard -q', root)
    truthy(checkpoint.exit_preview_mode(root))
    eq(' M tracked.txt', git_output(root, 'git status --short'))
  end)

  it('accepts only after the merge and stash cleanup succeed', function()
    vim.fn.writefile({ 'accepted' }, root .. '/tracked.txt')
    local original_branch = git.current_branch(root)
    local checkpoint_id = assert(checkpoint.create_checkpoint('accept state', root))
    truthy(checkpoint.enter_preview_mode(checkpoint_id, root))

    truthy(checkpoint.accept_checkpoint(root))
    eq(original_branch, git.current_branch(root))
    eq('accepted', table.concat(vim.fn.readfile(root .. '/tracked.txt'), '\n'))
    eq('', git_output(root, 'git status --short'))
    eq('', git_output(root, 'git stash list'))
    falsy(checkpoint.load_state(root) ~= nil)
  end)

  it('rolls back a failed accept merge and retains the recovery stash', function()
    vim.fn.writefile({ 'checkpoint version' }, root .. '/tracked.txt')
    local checkpoint_id = assert(checkpoint.create_checkpoint('conflicting accept', root))
    truthy(checkpoint.enter_preview_mode(checkpoint_id, root))
    local state = assert(checkpoint.load_state(root))
    local conflict_worktree = helpers.tmpdir()
    vim.fn.delete(conflict_worktree, 'rf')
    helpers.git(
      'git worktree add -q ' .. vim.fn.shellescape(conflict_worktree) .. ' ' .. vim.fn.shellescape(state.original_branch),
      root
    )
    vim.fn.writefile({ 'branch version' }, conflict_worktree .. '/tracked.txt')
    helpers.git('git add tracked.txt && git commit -qm conflict', conflict_worktree)
    helpers.git('git worktree remove --force ' .. vim.fn.shellescape(conflict_worktree), root)

    falsy(checkpoint.accept_checkpoint(root))
    local retained = assert(checkpoint.load_state(root))
    eq('preview', retained.mode)
    eq(state.stash_oid, retained.stash_oid)
    eq(retained.checkpoint_sha, git_output(root, 'git rev-parse HEAD'))
    eq('', git_output(root, 'git status --short'))

    helpers.git(
      'git branch -f '
        .. vim.fn.shellescape(retained.original_branch)
        .. ' '
        .. vim.fn.shellescape(retained.original_head),
      root
    )
    truthy(checkpoint.exit_preview_mode(root))
    eq(' M tracked.txt', git_output(root, 'git status --short'))
  end)
end)

describe('background agent state', function()
  local root_one
  local root_two
  local state_dir
  local original_cwd

  before_each(function()
    original_cwd = vim.fn.getcwd()
    root_one = helpers.tmpdir()
    root_two = helpers.tmpdir()
    state_dir = helpers.tmpdir()
    helpers.init_repo(root_one)
    helpers.init_repo(root_two)
    commit_file(root_one, 'one.txt', { 'one' })
    commit_file(root_two, 'two.txt', { 'two' })
    project_state.get_state_file = function() return state_dir .. '/state.json' end
    project_state.clear_cache()
  end)

  after_each(function()
    vim.fn.chdir(original_cwd)
    vim.fn.delete(root_one, 'rf')
    vim.fn.delete(root_two, 'rf')
    vim.fn.delete(state_dir, 'rf')
    project_state.clear_cache()
  end)

  it('keeps registries isolated across cwd changes', function()
    local one_dir = root_one .. '/agent-one'
    local two_dir = root_two .. '/agent-two'
    vim.fn.mkdir(one_dir, 'p')
    vim.fn.mkdir(two_dir, 'p')
    vim.fn.writefile({ 'one' }, one_dir .. '/mission.log')
    vim.fn.writefile({ 'two' }, two_dir .. '/mission.log')

    local one_id = assert(registry.register('one', one_dir, '@1', 'one', {}, root_one))
    local two_id = assert(registry.register('two', two_dir, '@2', 'two', {}, root_two))
    eq(1, #registry.get_project_agents(root_one))
    eq(1, #registry.get_project_agents(root_two))

    vim.fn.chdir(root_one)
    truthy(registry.update_progress(one_id, 'changed', root_one))
    vim.fn.chdir(root_two)
    truthy(registry.update_status(two_id, 'completed', root_two))

    eq('changed', assert(registry.get(one_id, root_one)).progress)
    eq('active', assert(registry.get(one_id, root_one)).status)
    eq('completed', assert(registry.get(two_id, root_two)).status)
    falsy(registry.get(one_id, root_two) ~= nil)
  end)

  it('migrates a legacy registry only after it is persisted', function()
    local legacy_path = state_dir .. '/legacy-registry.json'
    vim.fn.writefile({ vim.json.encode({
      legacy = {
        id = 'legacy',
        task = 'old task',
        work_dir = root_one .. '/old-agent',
        status = 'completed',
      },
    }) }, legacy_path)

    truthy(registry.setup({ legacy_path = legacy_path }, root_one))
    eq('old task', registry.get('legacy', root_one).task)
    falsy(vim.fn.filereadable(legacy_path) == 1)
  end)

  it('keeps a malformed legacy registry for manual recovery', function()
    local legacy_path = state_dir .. '/legacy-registry.json'
    vim.fn.writefile({ '{not-json' }, legacy_path)

    falsy(registry.setup({ legacy_path = legacy_path }, root_one))
    truthy(vim.fn.filereadable(legacy_path) == 1)
  end)

  it('checks the agent limit before creating resources', function()
    local original_validate = background_utils.tmux.validate
    local original_registry_validate = registry.validate_agents
    local original_active_count = registry.get_active_count
    local original_create = worktree.create
    local worktree_called = false
    background_utils.tmux.validate = function() return true end
    registry.validate_agents = function() return true end
    registry.get_active_count = function() return 1 end
    worktree.create = function()
      worktree_called = true
      return false, 'should not run'
    end
    background_config.setup({ work_dir = '.agent-work', max_agents = 1 })
    vim.fn.chdir(root_one)

    local ok, err = creator.create('limited task')

    background_utils.tmux.validate = original_validate
    registry.validate_agents = original_registry_validate
    registry.get_active_count = original_active_count
    worktree.create = original_create
    background_config.setup({})
    falsy(ok)
    truthy(tostring(err):match('Agent limit reached') ~= nil)
    falsy(worktree_called)
    falsy(vim.loop.fs_stat(root_one .. '/.agent-work') ~= nil)
  end)

  it('forks uncommitted changes without disturbing the main worktree', function()
    vim.fn.writefile({ '.agent-work/' }, root_one .. '/.gitignore')
    helpers.git('git add .gitignore && git commit -qm ignore-agent-work', root_one)
    local agent_dir = root_one .. '/.agent-work/agent-worktree'
    vim.fn.writefile({ 'staged' }, root_one .. '/one.txt')
    helpers.git('git add one.txt', root_one)
    vim.fn.writefile({ 'staged', 'unstaged' }, root_one .. '/one.txt')
    vim.fn.writefile({ 'untracked' }, root_one .. '/new.txt')
    local status_before = git_output(root_one, 'git status --short')
    local index_before = git_output(root_one, 'git diff --cached --binary')
    local worktree_before = git_output(root_one, 'git diff --binary')

    local ok, info = worktree.create(agent_dir, { type = 'stash' }, 'test fork', root_one)
    truthy(ok, tostring(info))
    eq(status_before, git_output(root_one, 'git status --short'))
    eq(index_before, git_output(root_one, 'git diff --cached --binary'))
    eq(worktree_before, git_output(root_one, 'git diff --binary'))
    eq('', git_output(root_one, 'git stash list'))
    eq('staged\nunstaged', table.concat(vim.fn.readfile(agent_dir .. '/one.txt'), '\n'))
    eq('untracked', table.concat(vim.fn.readfile(agent_dir .. '/new.txt'), '\n'))

    truthy(worktree.remove(agent_dir, root_one))
    falsy(vim.loop.fs_stat(agent_dir) ~= nil)
  end)

  it('restores the main stash when worktree creation fails', function()
    vim.fn.writefile({ 'staged' }, root_one .. '/one.txt')
    helpers.git('git add one.txt', root_one)
    vim.fn.writefile({ 'staged', 'unstaged' }, root_one .. '/one.txt')
    vim.fn.writefile({ 'untracked' }, root_one .. '/new.txt')
    local status_before = git_output(root_one, 'git status --short')
    local index_before = git_output(root_one, 'git diff --cached --binary')
    local worktree_before = git_output(root_one, 'git diff --binary')
    local original_create = git.create_worktree
    git.create_worktree = function() return false, 'forced worktree failure' end

    local ok, err = worktree.create(
      root_one .. '/failed-worktree',
      { type = 'stash' },
      'failed fork',
      root_one
    )
    git.create_worktree = original_create

    falsy(ok)
    truthy(tostring(err):match('forced worktree failure') ~= nil)
    eq(status_before, git_output(root_one, 'git status --short'))
    eq(index_before, git_output(root_one, 'git diff --cached --binary'))
    eq(worktree_before, git_output(root_one, 'git diff --binary'))
    eq('', git_output(root_one, 'git stash list'))
  end)

  it('does not overwrite tracked Claude settings in new worktrees', function()
    vim.fn.mkdir(root_one .. '/.claude', 'p')
    vim.fn.writefile({ '{"custom":true}' }, root_one .. '/.claude/settings.json')
    helpers.git('git add .claude/settings.json && git commit -qm settings', root_one)
    local agent_dir = root_one .. '/settings-worktree'

    local ok, info = git.create_worktree(agent_dir, git.current_branch(root_one), root_one)
    truthy(ok, tostring(info))
    eq('{"custom":true}', table.concat(vim.fn.readfile(agent_dir .. '/.claude/settings.json'), '\n'))
    truthy(git.remove_worktree(agent_dir, root_one))
  end)
end)
