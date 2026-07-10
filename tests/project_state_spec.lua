local eq = assert.are.equal
local truthy = assert.is_true
local falsy = assert.is_false

local project_state = require 'nvim-claude.project-state'
local helpers = require 'tests.helpers'
local utils = require 'nvim-claude.utils'

describe('project-state storage', function()
  local root
  local state_dir
  local state_file

  before_each(function()
    root = helpers.tmpdir()
    helpers.init_repo(root)
    state_dir = helpers.tmpdir()
    state_file = state_dir .. '/state.json'
    project_state.get_state_file = function() return state_file end
    project_state.clear_cache()
    utils.clear_project_root_cache()
  end)

  after_each(function()
    vim.fn.delete(root, 'rf')
    vim.fn.delete(state_dir, 'rf')
    project_state.clear_cache()
    utils.clear_project_root_cache()
  end)

  it('updates a project atomically without leaking mutable cached values', function()
    truthy(project_state.set(root, 'alpha', { value = 1 }))
    truthy(project_state.update_project(root, function(state)
      state.beta = { value = 2 }
      return state
    end))

    local alpha = project_state.get(root, 'alpha')
    alpha.value = 99

    eq(1, project_state.get(root, 'alpha').value)
    eq(2, project_state.get(root, 'beta').value)
    eq(0, #vim.fn.glob(state_file .. '.tmp.*', false, true))
    falsy(vim.fn.isdirectory(state_file .. '.lock') == 1)
  end)

  it('refuses to overwrite corrupt state', function()
    vim.fn.writefile({ '{not-json' }, state_file)
    project_state.clear_cache()

    falsy(project_state.set(root, 'alpha', true))
    eq('{not-json', table.concat(vim.fn.readfile(state_file), '\n'))
  end)

  it('refuses to replace an existing state file that cannot be read', function()
    truthy(project_state.set(root, 'preserved', true))
    local original_read = utils.read_file
    utils.read_file = function(path)
      if path == state_file then return nil, 'forced read failure' end
      return original_read(path)
    end
    project_state.clear_cache()

    local saved = project_state.set(root, 'lost', true)
    utils.read_file = original_read
    project_state.clear_cache()

    falsy(saved)
    truthy(project_state.get(root, 'preserved'))
    falsy(project_state.get(root, 'lost') ~= nil)
  end)

  it('releases the storage lock when an updater fails', function()
    falsy(project_state.update_project(root, function()
      error('forced updater failure')
    end))

    falsy(vim.fn.isdirectory(state_file .. '.lock') == 1)
    truthy(project_state.set(root, 'recovered', true))
  end)

  it('recovers a lock owned by a dead process', function()
    vim.fn.mkdir(state_file .. '.lock', 'p')
    vim.fn.writefile({ '999999999:dead' }, state_file .. '.lock/owner')

    truthy(project_state.set(root, 'after_stale_lock', true))
    truthy(project_state.get(root, 'after_stale_lock'))
    falsy(vim.fn.isdirectory(state_file .. '.lock') == 1)
  end)

  it('preserves updates from concurrent Neovim processes', function()
    local completed = 0
    local exit_codes = {}

    for index = 1, 6 do
      local lua = string.format(
        "local state=require('nvim-claude.project-state'); state.get_state_file=function() return %q end; state.clear_cache(); assert(state.set(%q, %q, true))",
        state_file,
        root,
        'worker_' .. index
      )
      vim.fn.jobstart({
        'nvim',
        '--headless',
        '-u',
        'tests/minimal_init.lua',
        '-c',
        'lua ' .. lua,
        '-c',
        'qa!',
      }, {
        on_exit = function(_, code)
          table.insert(exit_codes, code)
          completed = completed + 1
        end,
      })
    end

    truthy(vim.wait(10000, function() return completed == 6 end, 20))
    for _, code in ipairs(exit_codes) do eq(0, code) end

    project_state.clear_cache()
    for index = 1, 6 do truthy(project_state.get(root, 'worker_' .. index)) end
  end)

  it('merges changes saved from a loaded snapshot with newer state', function()
    local snapshot = project_state.load_all_states()
    snapshot.__cursor_cpp_global__ = { cursor_access_token = 'token' }

    truthy(project_state.set(root, 'concurrent_feature', true))
    truthy(project_state.save_all_states(snapshot))

    truthy(project_state.get(root, 'concurrent_feature'))
    local all_states = project_state.load_all_states()
    eq('token', all_states.__cursor_cpp_global__.cursor_access_token)
  end)

  it('refreshes a loaded snapshot after each successful save', function()
    local snapshot = project_state.load_all_states()
    snapshot.__cursor_cpp_global__ = { cursor_access_token = 'first' }
    truthy(project_state.save_all_states(snapshot))

    local concurrent = project_state.load_all_states()
    concurrent.__cursor_cpp_global__.cursor_access_token = 'concurrent'
    truthy(project_state.save_all_states(concurrent))

    snapshot.__cursor_cpp_global__.cursor_refresh_token = 'refresh'
    truthy(project_state.save_all_states(snapshot))

    local final = project_state.load_all_states().__cursor_cpp_global__
    eq('concurrent', final.cursor_access_token)
    eq('refresh', final.cursor_refresh_token)
  end)

  it('does not save a table returned from a failed load', function()
    truthy(project_state.set(root, 'preserved', true))
    local original_read = utils.read_file
    utils.read_file = function(path)
      if path == state_file then return nil, 'forced read failure' end
      return original_read(path)
    end
    project_state.clear_cache()
    local failed = project_state.load_all_states()
    utils.read_file = original_read
    project_state.clear_cache()

    failed.replacement = true
    falsy(project_state.save_all_states(failed))
    truthy(project_state.get(root, 'preserved'))
  end)

  it('keeps failed and unknown legacy migration files', function()
    local legacy_dir = root .. '/.nvim-claude'
    vim.fn.mkdir(legacy_dir, 'p')
    vim.fn.writefile({ '{not-json' }, legacy_dir .. '/inline-diff-state.json')
    vim.fn.writefile({ 'keep' }, legacy_dir .. '/notes.txt')

    falsy(project_state.migrate_local_state(root))
    truthy(vim.fn.filereadable(legacy_dir .. '/inline-diff-state.json') == 1)
    truthy(vim.fn.filereadable(legacy_dir .. '/notes.txt') == 1)
  end)

  it('finds the project root for a new file below missing directories', function()
    local new_file = root .. '/new/nested/file.lua'

    eq(vim.fn.resolve(root), utils.get_project_root_for_file(new_file))
  end)
end)
