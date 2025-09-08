-- Codex provider: background agent helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux
local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local logger = require('nvim-claude.logger')

local M = {}

function M.generate_window_name()
  return 'codex-' .. utils.timestamp()
end

-- For Codex, inject @import into AGENTS.md instead of CLAUDE.md
function M.append_to_context(agent_dir)
  if not agent_dir or agent_dir == '' then return false end
  local agents_md_path = agent_dir .. '/AGENTS.md'
  local content = utils.file_exists(agents_md_path) and (utils.read_file(agents_md_path) or '') or ''
  logger.debug('provider.codex.background', 'append_to_context: read AGENTS.md', {
    path = agents_md_path,
    exists = utils.file_exists(agents_md_path),
    length = #content,
  })
  local import_line = '@import agent-instructions.md'
  local has_import = content:match('@import%s+agent%-instructions%.md') ~= nil
  local has_see = content:match('See%s+@agent%-instructions%.md') ~= nil
  if not (has_import or has_see) then
    local new_content
    if content == '' then
      new_content = import_line .. '\n'
    else
      if not content:match('\n$') then content = content .. '\n' end
      new_content = content .. '\n' .. import_line .. '\n'
    end
    local ok = utils.write_file(agents_md_path, new_content)
    if not ok then
      local f = io.open(agents_md_path, content == '' and 'w' or 'a')
      if f then
        if content == '' then f:write(import_line .. '\n') else f:write('\n\n' .. import_line .. '\n') end
        f:close()
      end
    end
  end
  return true
end

function M.launch_agent_pane(window_id, cwd, initial_text)
  if not window_id then return nil end
  local pane_id = tmux.split_window(window_id, 'h', 40)
  if not pane_id then return nil end
  tmux.send_to_pane(pane_id, 'cd ' .. cwd)
  tmux.send_to_pane(pane_id, cfg.background_spawn or 'codex')
  vim.defer_fn(function()
    if initial_text and initial_text ~= '' then
      tmux.send_text_to_pane(pane_id, initial_text)
    end
  end, 1000)
  return pane_id
end

return M

