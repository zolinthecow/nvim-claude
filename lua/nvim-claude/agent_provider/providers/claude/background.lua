-- Claude provider: background agent pane helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux

local M = {}
local cfg = require 'nvim-claude.agent_provider.providers.claude.config'

function M.generate_window_name()
  return 'claude-' .. utils.timestamp()
end

function M.append_to_context(agent_dir)
  if not agent_dir or agent_dir == '' then
    return false
  end
  local claude_md_path = agent_dir .. '/CLAUDE.md'
  local content = utils.file_exists(claude_md_path) and (utils.read_file(claude_md_path) or '') or ''
  -- Prefer canonical @import directive; also avoid duplicating legacy "See @agent-instructions.md" lines
  local import_line = '@import agent-instructions.md'
  local has_import = content:match '@import%s+agent%-instructions%.md' ~= nil
  local has_see = content:match 'See%s+@agent%-instructions%.md' ~= nil
  if not (has_import or has_see) then
    -- If file is empty replace content entirely
    if content == '' then
      local ok = utils.write_file(claude_md_path, import_line .. '\n')
      if not ok then
        -- Fallback: try raw append mode
        local f = io.open(claude_md_path, 'w')
        if f then
          f:write(import_line .. '\n')
          f:close()
        end
      end
    else
      local new_content = content
      if not new_content:match '\n$' then
        new_content = new_content .. '\n'
      end
      new_content = new_content .. '\n' .. import_line .. '\n'
      local ok = utils.write_file(claude_md_path, new_content)
      if not ok then
        -- Fallback: append in-place
        local f = io.open(claude_md_path, 'a')
        if f then
          f:write('\n\n' .. import_line .. '\n')
          f:close()
        end
      end
    end
  end
  return true
end

function M.launch_agent_pane(window_id, cwd, initial_text)
  if not window_id then
    return nil
  end
  local pane_id = tmux.split_window(window_id, 'h', 40)
  if not pane_id then
    return nil
  end
  tmux.send_to_pane(pane_id, 'cd ' .. cwd)
  tmux.send_to_pane(pane_id, cfg.background_spawn or 'claude --dangerously-skip-permissions')
  vim.defer_fn(function()
    if initial_text and initial_text ~= '' then
      tmux.send_text_to_pane(pane_id, initial_text)
    end
  end, 1000)
  return pane_id
end

return M
