local eq = assert.are.same
local falsy = assert.falsy
local truthy = assert.truthy

local helpers = require 'tests.helpers'
local utils = require 'nvim-claude.utils'

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  assert(utils.write_file(path, content))
end

local function read_json(path)
  local content = utils.read_file(path)
  truthy(content)
  return vim.json.decode(content)
end

local function find_hook(settings, section, command_fragment)
  for _, entry in ipairs(settings.hooks[section] or {}) do
    for _, hook in ipairs(entry.hooks or {}) do
      if hook.command and hook.command:find(command_fragment, 1, true) then return hook end
    end
  end
  return nil
end

describe('provider hook safety', function()
  local root
  local original_get_project_root
  local original_codex_home
  local original_xdg_config_home

  before_each(function()
    root = helpers.tmpdir()
    original_get_project_root = utils.get_project_root
    original_codex_home = vim.env.CODEX_HOME
    original_xdg_config_home = vim.env.XDG_CONFIG_HOME
    utils.get_project_root = function() return root end
  end)

  after_each(function()
    utils.get_project_root = original_get_project_root
    vim.env.CODEX_HOME = original_codex_home
    vim.env.XDG_CONFIG_HOME = original_xdg_config_home
    vim.fn.delete(root, 'rf')
  end)

  it('preserves unrelated Claude hooks and permissions', function()
    local path = root .. '/.claude/settings.local.json'
    local permissions = {
      allow = { 'Read', 'Bash(git status:*)' },
      deny = { 'Write(.env)' },
      defaultMode = 'plan',
    }
    local settings = {
      permissions = permissions,
      custom = { keep = true },
      hooks = {
        PreToolUse = {
          {
            matcher = 'Other',
            hooks = { { type = 'command', command = '/opt/team/scripts/pre-hook-wrapper.sh' } },
          },
        },
        PostToolUse = {},
        Stop = {},
        UserPromptSubmit = {},
      },
    }
    write_file(path, vim.json.encode(settings))

    local hooks = require 'nvim-claude.agent_provider.providers.claude.hooks'
    truthy(hooks.install())
    local installed = read_json(path)
    eq(permissions, installed.permissions)
    eq({ keep = true }, installed.custom)
    truthy(find_hook(installed, 'PreToolUse', '/opt/team/scripts/pre-hook-wrapper.sh'))
    truthy(find_hook(installed, 'PreToolUse', '/claude-hooks/pre-hook-wrapper.sh'))
    falsy(vim.tbl_contains(installed.permissions.allow, 'Bash'))

    truthy(hooks.uninstall())
    local uninstalled = read_json(path)
    eq(permissions, uninstalled.permissions)
    truthy(find_hook(uninstalled, 'PreToolUse', '/opt/team/scripts/pre-hook-wrapper.sh'))
    falsy(find_hook(uninstalled, 'PreToolUse', '/claude-hooks/pre-hook-wrapper.sh'))
  end)

  it('does not overwrite malformed Claude settings', function()
    local path = root .. '/.claude/settings.local.json'
    local malformed = '{ this is not json'
    write_file(path, malformed)

    local hooks = require 'nvim-claude.agent_provider.providers.claude.hooks'
    falsy(hooks.install())
    eq(malformed, utils.read_file(path))
    falsy(hooks.uninstall())
    eq(malformed, utils.read_file(path))
  end)

  it('leaves Claude settings byte-for-byte unchanged when nothing is installed', function()
    local path = root .. '/.claude/settings.local.json'
    local original = '{"permissions":{"allow":["Read"]},"custom":true}\n'
    write_file(path, original)

    local hooks = require 'nvim-claude.agent_provider.providers.claude.hooks'
    truthy(hooks.uninstall())
    eq(original, utils.read_file(path))
  end)

  it('never executes compound rm command fragments in Claude hooks', function()
    local marker = root .. '/executed'
    local victim = root .. '/victim'
    write_file(victim, 'keep')
    local payload = vim.json.encode({
      cwd = root,
      tool_input = { command = 'rm victim; touch ' .. marker },
    })
    local wrapper = vim.loop.cwd()
      .. '/lua/nvim-claude/agent_provider/providers/claude/claude-hooks/bash-hook-wrapper.sh'

    vim.fn.system({ 'bash', wrapper }, payload)
    falsy(utils.file_exists(marker))
    truthy(utils.file_exists(victim))
  end)

  it('preserves user Codex tables and removes only its marked block', function()
    local home = root .. '/codex'
    local path = home .. '/config.toml'
    local original = table.concat({
      '[hooks]',
      "command = 'keep'",
      '',
      '[mcp_servers.other]',
      "command = 'other'",
      '',
    }, '\n')
    vim.env.CODEX_HOME = home
    write_file(path, original)

    package.loaded['nvim-claude.agent_provider.providers.codex.hooks'] = nil
    local hooks = require 'nvim-claude.agent_provider.providers.codex.hooks'
    truthy(hooks.install())
    local installed = assert(utils.read_file(path))
    truthy(installed:find('[hooks]', 1, true))
    truthy(installed:find("command = 'keep'", 1, true))
    truthy(installed:find('# BEGIN nvim-claude managed Codex configuration', 1, true))

    truthy(hooks.uninstall())
    eq(original, utils.read_file(path))
  end)

  it('refuses to replace user Codex OTEL or malformed TOML', function()
    local home = root .. '/codex'
    local path = home .. '/config.toml'
    vim.env.CODEX_HOME = home
    package.loaded['nvim-claude.agent_provider.providers.codex.hooks'] = nil
    local hooks = require 'nvim-claude.agent_provider.providers.codex.hooks'

    local user_otel = "[otel]\nenvironment = 'production'\n"
    write_file(path, user_otel)
    falsy(hooks.install())
    eq(user_otel, utils.read_file(path))
    truthy(hooks.uninstall())
    eq(user_otel, utils.read_file(path))

    local malformed = '[broken\nvalue ='
    write_file(path, malformed)
    falsy(hooks.install())
    eq(malformed, utils.read_file(path))
  end)

  it('leaves Codex config unchanged when management markers are incomplete', function()
    local home = root .. '/codex'
    local path = home .. '/config.toml'
    local malformed_markers = '# BEGIN nvim-claude managed Codex configuration\n[other]\nvalue = true\n'
    vim.env.CODEX_HOME = home
    write_file(path, malformed_markers)

    package.loaded['nvim-claude.agent_provider.providers.codex.hooks'] = nil
    local hooks = require 'nvim-claude.agent_provider.providers.codex.hooks'
    falsy(hooks.install())
    eq(malformed_markers, utils.read_file(path))
    falsy(hooks.uninstall())
    eq(malformed_markers, utils.read_file(path))
  end)

  it('does not shell-evaluate rm commands in the generated OpenCode plugin', function()
    if vim.fn.executable('node') ~= 1 then return end
    vim.env.XDG_CONFIG_HOME = root .. '/xdg'
    package.loaded['nvim-claude.agent_provider.providers.opencode.hooks'] = nil
    local hooks = require 'nvim-claude.agent_provider.providers.opencode.hooks'
    truthy(hooks.install())

    local generated = root .. '/xdg/opencode/plugins/nvim-claude.js'
    local module_path = root .. '/plugin.mjs'
    write_file(module_path, assert(utils.read_file(generated)))
    local runner = root .. '/runner.mjs'
    write_file(runner, [[
import { execSync } from 'child_process'
import fs from 'fs'
import { NvimClaude } from './plugin.mjs'

let cwd = process.argv[2]
const marker = process.argv[3]
const dollar = (_strings, value) => {
  if (value && value.raw) execSync(value.raw, { cwd, stdio: 'ignore' })
  return { text: async () => '' }
}
dollar.cwd = (directory) => { cwd = directory; return dollar }
dollar.nothrow = () => dollar

const plugin = await NvimClaude({ directory: cwd, $: dollar })
await plugin['tool.execute.before'](
  { callID: 'unsafe-rm', tool: 'bash' },
  { args: { command: `rm victim; touch ${marker}` } },
)
if (fs.existsSync(marker)) process.exit(2)
]])

    write_file(root .. '/victim', 'keep')
    local marker = root .. '/opencode-executed'
    vim.fn.system({ 'node', runner, root, marker })
    eq(0, vim.v.shell_error)
    falsy(utils.file_exists(marker))
  end)
end)

describe('Codex background isolation', function()
  local root
  local tmux
  local cfg
  local originals
  local original_codex_home

  before_each(function()
    root = helpers.tmpdir()
    tmux = utils.tmux
    cfg = require 'nvim-claude.agent_provider.providers.codex.config'
    originals = {
      split_window = tmux.split_window,
      send_to_pane = tmux.send_to_pane,
      send_text_to_pane = tmux.send_text_to_pane,
      kill_pane = tmux.kill_pane,
      background_spawn = cfg.background_spawn,
    }
    original_codex_home = vim.env.CODEX_HOME
  end)

  after_each(function()
    tmux.split_window = originals.split_window
    tmux.send_to_pane = originals.send_to_pane
    tmux.send_text_to_pane = originals.send_text_to_pane
    tmux.kill_pane = originals.kill_pane
    cfg.background_spawn = originals.background_spawn
    vim.env.CODEX_HOME = original_codex_home
    vim.fn.delete(root, 'rf')
  end)

  it('keeps minimal credentials outside the worktree and cleans task state', function()
    local source_home = root .. '/user-codex'
    local worktree = root .. '/worktree'
    write_file(source_home .. '/auth.json', '{"token":"secret"}')
    write_file(source_home .. '/config.toml', "secret = 'do-not-copy'")
    vim.fn.mkdir(worktree, 'p')
    vim.env.CODEX_HOME = source_home
    cfg.background_spawn = 'true'

    local sent
    local send_count = 0
    tmux.split_window = function() return '%42' end
    tmux.send_to_pane = function(_, command)
      send_count = send_count + 1
      if send_count == 2 then sent = command end
      return true
    end
    tmux.send_text_to_pane = function() return true end
    tmux.kill_pane = function() return true end

    package.loaded['nvim-claude.agent_provider.providers.codex.background'] = nil
    local background = require 'nvim-claude.agent_provider.providers.codex.background'
    eq('%42', background.launch_agent_pane('@1', worktree, 'task text'))
    falsy(utils.file_exists(worktree .. '/.codex'))
    falsy(utils.file_exists(worktree .. '/.codex-task.txt'))

    local isolated_home = assert(sent:match("export CODEX_HOME='([^']+)';"))
    truthy(isolated_home:sub(1, #worktree) ~= worktree)
    eq('{"token":"secret"}', utils.read_file(isolated_home .. '/auth.json'))
    falsy(utils.file_exists(isolated_home .. '/config.toml'))
    truthy(utils.file_exists(isolated_home .. '/task.txt'))

    vim.fn.system(sent)
    eq(0, vim.v.shell_error)
    falsy(utils.file_exists(isolated_home))
  end)
end)

describe('Codex relay PID ownership', function()
  local root
  local original_runtime_dir

  before_each(function()
    root = helpers.tmpdir()
    original_runtime_dir = vim.env.XDG_RUNTIME_DIR
    vim.env.XDG_RUNTIME_DIR = root
  end)

  after_each(function()
    vim.env.XDG_RUNTIME_DIR = original_runtime_dir
    vim.fn.delete(root, 'rf')
  end)

  it('does not treat a reused PID as the relay process', function()
    local path = root .. '/nvim-claude-codex-otel-relay.pid'
    vim.fn.writefile({ tostring(vim.fn.getpid()) }, path)
    package.loaded['nvim-claude.agent_provider.providers.codex.relay'] = nil
    local relay = require 'nvim-claude.agent_provider.providers.codex.relay'

    eq('stopped', relay.status())
    falsy(relay.stop())
    falsy(utils.file_exists(path))
  end)
end)

describe('Codex OTEL prompt routing', function()
  local root
  local original_cwd
  local original_target
  local original_package_path

  before_each(function()
    root = helpers.tmpdir()
    original_cwd = vim.loop.cwd()
    original_package_path = package.path
    package.path = original_cwd .. '/lua/?.lua;' .. original_cwd .. '/lua/?/init.lua;' .. package.path
    original_target = vim.fn.getenv 'TARGET_FILE'
  end)

  after_each(function()
    vim.fn.chdir(original_cwd)
    package.path = original_package_path
    if original_target and original_target ~= vim.NIL and original_target ~= '' then
      vim.fn.setenv('TARGET_FILE', original_target)
    else
      vim.fn.setenv('TARGET_FILE', '')
    end
    vim.fn.delete(root, 'rf')
  end)

  it('uses payload cwd instead of Neovim cwd for prompt checkpoints', function()
    local ambient = root .. '/ambient'
    local payload_root = root .. '/payload'
    vim.fn.mkdir(ambient, 'p')
    vim.fn.mkdir(payload_root, 'p')
    helpers.init_repo(ambient)
    helpers.init_repo(payload_root)
    vim.fn.chdir(ambient)
    local resolved_ambient = helpers.git('git rev-parse --show-toplevel', ambient):gsub('%s+$', '')
    local resolved_payload = helpers.git('git rev-parse --show-toplevel', payload_root):gsub('%s+$', '')

    local called
    local sink = {
      is_edited_file = function() return false end,
      pre_tool_use = function() return true end,
      post_tool_use = function() return true end,
      user_prompt_submit = function(prompt)
        called = { prompt = prompt, target = vim.fn.getenv 'TARGET_FILE' }
        return true
      end,
    }

    package.loaded['nvim-claude.agent_provider.providers.codex.otel_listener'] = nil
    local listener = require 'nvim-claude.agent_provider.providers.codex.otel_listener'
    truthy(listener.setup({ event_sink = sink }))
    listener.process_payload({
      resourceLogs = {
        {
          resource = {
            attributes = {
              { key = 'cwd', value = { stringValue = payload_root } },
            },
          },
          scopeLogs = {
            {
              logRecords = {
                {
                  attributes = {
                    { key = 'event.name', value = { stringValue = 'codex.user_prompt' } },
                    { key = 'prompt', value = { stringValue = 'payload prompt' } },
                  },
                },
              },
            },
          },
        },
      },
    })
    eq({ prompt = 'payload prompt', target = resolved_payload }, called)
    eq(resolved_ambient, vim.loop.cwd())
  end)

  it('does not route a prompt with no payload project context to ambient cwd', function()
    local ambient = root .. '/ambient'
    vim.fn.mkdir(ambient, 'p')
    helpers.init_repo(ambient)
    vim.fn.chdir(ambient)

    local called = false
    local sink = {
      is_edited_file = function() return false end,
      pre_tool_use = function() return true end,
      post_tool_use = function() return true end,
      user_prompt_submit = function() called = true return true end,
    }
    package.loaded['nvim-claude.agent_provider.providers.codex.otel_listener'] = nil
    local listener = require 'nvim-claude.agent_provider.providers.codex.otel_listener'
    truthy(listener.setup({ event_sink = sink }))
    listener.process_payload({
      resourceLogs = {
        {
          scopeLogs = {
            {
              logRecords = {
                {
                  attributes = {
                    { key = 'event.name', value = { stringValue = 'codex.user_prompt' } },
                    { key = 'prompt', value = { stringValue = 'unscoped prompt' } },
                  },
                },
              },
            },
          },
        },
      },
    })

    falsy(called)
  end)

  it('uses project context resolved by the external relay', function()
    local payload_root = root .. '/payload'
    vim.fn.mkdir(payload_root, 'p')
    helpers.init_repo(payload_root)
    local resolved_payload = helpers.git('git rev-parse --show-toplevel', payload_root):gsub('%s+$', '')

    local called
    local sink = {
      is_edited_file = function() return false end,
      pre_tool_use = function() return true end,
      post_tool_use = function() return true end,
      user_prompt_submit = function(prompt)
        called = { prompt = prompt, target = vim.fn.getenv 'TARGET_FILE' }
        return true
      end,
    }
    package.loaded['nvim-claude.agent_provider.providers.codex.otel_listener'] = nil
    local listener = require 'nvim-claude.agent_provider.providers.codex.otel_listener'
    truthy(listener.setup({ event_sink = sink }))
    listener.process_payload({
      resourceLogs = {
        {
          scopeLogs = {
            {
              logRecords = {
                {
                  attributes = {
                    { key = 'event.name', value = { stringValue = 'codex.user_prompt' } },
                    { key = 'prompt', value = { stringValue = 'relayed prompt' } },
                  },
                },
              },
            },
          },
        },
      },
    }, payload_root)

    eq({ prompt = 'relayed prompt', target = resolved_payload }, called)
  end)
end)

describe('provider public diagnostics', function()
  it('exposes provider config through the facade', function()
    local provider = require 'nvim-claude.agent_provider'
    provider.setup({ provider = 'claude', claude = { spawn_command = 'claude-test' } })
    local info = provider.debug_info()
    eq('claude', info.name)
    eq('claude-test', info.spawn_command)
    truthy(type(info.background_spawn) == 'string')
    truthy(type(info.pane_title) == 'string')
  end)
end)
