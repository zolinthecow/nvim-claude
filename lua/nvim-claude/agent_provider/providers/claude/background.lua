-- Claude provider: background agent pane helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux

local M = {}
local cfg = require 'nvim-claude.agent_provider.providers.claude.config'
local logger = require 'nvim-claude.logger'

function M.generate_window_name()
  return 'claude-' .. utils.timestamp()
end

function M.append_to_context(agent_dir)
  if not agent_dir or agent_dir == '' then
    return false
  end
  local claude_md_path = agent_dir .. '/CLAUDE.md'
  local content = utils.file_exists(claude_md_path) and (utils.read_file(claude_md_path) or '') or ''
  logger.debug('provider.claude.background', 'append_to_context: read CLAUDE.md', {
    agent_dir = agent_dir,
    path = claude_md_path,
    exists = utils.file_exists(claude_md_path),
    length = #(content or ''),
    head = (content or ''):sub(1, 80),
  })
  -- Prefer canonical @import directive; also avoid duplicating legacy "See @agent-instructions.md" lines
  local import_line = '@import agent-instructions.md'
  local has_import = content:match '@import%s+agent%-instructions%.md' ~= nil
  local has_see = content:match 'See%s+@agent%-instructions%.md' ~= nil
  logger.debug('provider.claude.background', 'append_to_context: detection', {
    has_import = has_import,
    has_see = has_see,
  })
  if not (has_import or has_see) then
    -- If file is empty replace content entirely
    if content == '' then
      logger.info('provider.claude.background', 'append_to_context: writing import (replace)', { path = claude_md_path })
      local ok = utils.write_file(claude_md_path, import_line .. '\n')
      if not ok then
        -- Fallback: try raw append mode
        logger.warn('provider.claude.background', 'append_to_context: write_file failed (replace), falling back to raw write', { path = claude_md_path })
        local f = io.open(claude_md_path, 'w')
        if f then
          f:write(import_line .. '\n')
          f:close()
          logger.info('provider.claude.background', 'append_to_context: raw write succeeded', { path = claude_md_path })
        end
      end
    else
      local new_content = content
      if not new_content:match '\n$' then
        new_content = new_content .. '\n'
      end
      new_content = new_content .. '\n' .. import_line .. '\n'
      logger.info('provider.claude.background', 'append_to_context: writing import (append)', { path = claude_md_path })
      local ok = utils.write_file(claude_md_path, new_content)
      if not ok then
        -- Fallback: append in-place
        logger.warn('provider.claude.background', 'append_to_context: write_file failed (append), falling back to raw append', { path = claude_md_path })
        local f = io.open(claude_md_path, 'a')
        if f then
          f:write('\n\n' .. import_line .. '\n')
          f:close()
          logger.info('provider.claude.background', 'append_to_context: raw append succeeded', { path = claude_md_path })
        end
      end
    end
    -- Verify write
    local verify = utils.read_file(claude_md_path) or ''
    local ok_after = verify:match('@import%s+agent%-instructions%.md') or verify:match('See%s+@agent%-instructions%.md')
    logger.debug('provider.claude.background', 'append_to_context: verify content', {
      path = claude_md_path,
      length = #verify,
      head = verify:sub(1, 120),
      has_marker = ok_after and true or false,
    })
    if not ok_after then
      logger.error('provider.claude.background', 'append_to_context: import line missing after write', { path = claude_md_path })
      return false
    end
  else
    logger.debug('provider.claude.background', 'append_to_context: import already present, skipping', { path = claude_md_path })
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
