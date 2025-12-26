-- OpenCode provider: background agent helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux
local cfg = require('nvim-claude.agent_provider.providers.opencode.config')
local logger = require('nvim-claude.logger')

local M = {}

function M.generate_window_name()
  return 'opencode-' .. utils.timestamp()
end

-- For OpenCode, inline the agent instructions into OpenCode.md
function M.append_to_context(agent_dir)
  if not agent_dir or agent_dir == '' then
    return false
  end
  local opencode_md_path = agent_dir .. '/OpenCode.md'
  local content = utils.file_exists(opencode_md_path) and (utils.read_file(opencode_md_path) or '') or ''
  logger.debug('provider.opencode.background', 'append_to_context: read OpenCode.md', {
    path = opencode_md_path,
    exists = utils.file_exists(opencode_md_path),
    length = #content,
  })
  local instr_path = agent_dir .. '/agent-instructions.md'
  local instr = utils.file_exists(instr_path) and (utils.read_file(instr_path) or '') or ''
  if instr ~= '' then
    local new_content
    if content == '' then
      new_content = instr
    else
      if not content:match('\n$') then
        content = content .. '\n'
      end
      new_content = content .. '\n' .. instr
    end
    local ok = utils.write_file(opencode_md_path, new_content)
    if ok then
      pcall(vim.fn.delete, instr_path)
      logger.info('provider.opencode.background', 'append_to_context: appended instructions into OpenCode.md and removed agent-instructions.md', {
        opencode_md = opencode_md_path,
      })
    else
      logger.warn('provider.opencode.background', 'append_to_context: failed to write OpenCode.md; keeping agent-instructions.md')
    end
  else
    logger.debug('provider.opencode.background', 'append_to_context: no agent-instructions.md to inline')
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
  tmux.send_to_pane(pane_id, 'cd ' .. vim.fn.shellescape(cwd))
  tmux.send_to_pane(pane_id, cfg.background_spawn or 'opencode')
  vim.defer_fn(function()
    if initial_text and initial_text ~= '' then
      tmux.send_text_to_pane(pane_id, initial_text)
    end
  end, 2000)
  return pane_id
end

return M
