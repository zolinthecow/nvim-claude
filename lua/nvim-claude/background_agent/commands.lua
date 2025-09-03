-- Background agent user commands (feature-scoped)

local M = {}

local function define(name, fn, opts)
  pcall(vim.api.nvim_create_user_command, name, fn, opts or {})
end

function M.register(claude)
  local ba = require('nvim-claude.background_agent')

  -- Start background agent (UI if no args)
  define('ClaudeBg', function(opts)
    local task = (opts and opts.args) or ''
    if task == '' then
      ba.start_create_flow()
    else
      ba.create_agent(task, nil)
    end
  end, { desc = 'Start a background Claude agent', nargs = '*' })

  -- List agents (switch on Enter, d to diff, k to kill)
  define('ClaudeAgents', function() ba.show_agent_list() end, { desc = 'List all Claude agents' })

  -- Kill agent by id or open kill UI
  define('ClaudeKill', function(opts)
    local id = (opts and opts.args) or ''
    if id == '' then
      ba.show_kill_ui()
    else
      ba.kill_agent(id)
    end
  end, {
    desc = 'Kill a Claude agent', nargs = '?',
    complete = function()
      local ids = {}
      for _, a in ipairs(ba.registry_agents()) do if a.status == 'active' then table.insert(ids, a.id) end end
      return ids
    end
  })

  define('ClaudeKillAll', function() ba.kill_all() end, { desc = 'Kill all active Claude agents' })

  define('ClaudeClean', function()
    local days = (claude and claude.config and claude.config.agents and claude.config.agents.cleanup_days) or 30
    vim.ui.select(
      { 'Clean completed agents', 'Clean agents older than ' .. days .. ' days', 'Clean ALL inactive agents', 'Cancel' },
      { prompt = 'Select cleanup option:' },
      function(choice)
        if choice == 'Clean completed agents' then
          ba.cleanup_completed()
        elseif choice and choice:match('older than') then
          ba.cleanup_older_than(days)
        elseif choice == 'Clean ALL inactive agents' then
          ba.cleanup_all_inactive()
        end
      end
    )
  end, { desc = 'Clean up old Claude agents' })

  define('ClaudeCleanOrphans', function() ba.clean_orphans() end, { desc = 'Clean orphaned agent directories' })

  define('ClaudeRebuildRegistry', function() ba.rebuild_registry() end, { desc = 'Rebuild agent registry from existing directories' })

  define('ClaudeDiffAgent', function(opts)
    local id = (opts and opts.args) or ''
    if id ~= '' then
      ba.open_diff_by_id(id)
    else
      ba.show_agent_list()
    end
  end, {
    desc = 'Review agent changes with diffview', nargs = '?',
    complete = function()
      local ids = {}
      for _, a in ipairs(ba.registry_agents()) do table.insert(ids, a.id) end
      return ids
    end
  })
end

return M

