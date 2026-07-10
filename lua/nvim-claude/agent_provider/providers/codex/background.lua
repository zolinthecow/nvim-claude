-- Codex provider: background agent helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux
local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local logger = require('nvim-claude.logger')

local M = {}
local uv = vim.uv or vim.loop

local function remove_tree(path)
  pcall(vim.fn.delete, path, 'rf')
end

local function prepare_codex_home()
  local path = vim.fn.tempname() .. '-nvim-claude-codex'
  if not utils.ensure_dir(path) then return nil, 'failed to create temporary CODEX_HOME' end
  pcall(uv.fs_chmod, path, 448)

  local source_home = vim.env.CODEX_HOME or vim.fn.expand('~/.codex')
  local source_auth = source_home .. '/auth.json'
  if vim.fn.filereadable(source_auth) == 1 then
    local ok, err = uv.fs_copyfile(source_auth, path .. '/auth.json')
    if not ok then
      remove_tree(path)
      return nil, err or 'failed to copy Codex authentication'
    end
    pcall(uv.fs_chmod, path .. '/auth.json', 384)
  end

  return path
end

function M.generate_window_name()
  return 'codex-' .. utils.timestamp()
end

-- For Codex, inline the agent instructions into AGENTS.md (no @import)
function M.append_to_context(agent_dir)
  if not agent_dir or agent_dir == '' then return false end
  local agents_md_path = agent_dir .. '/AGENTS.md'
  local content = utils.file_exists(agents_md_path) and (utils.read_file(agents_md_path) or '') or ''
  logger.debug('provider.codex.background', 'append_to_context: read AGENTS.md', {
    path = agents_md_path,
    exists = utils.file_exists(agents_md_path),
    length = #content,
  })
  -- Read generated instructions (created by background_agent.create)
  local instr_path = agent_dir .. '/agent-instructions.md'
  local instr = utils.file_exists(instr_path) and (utils.read_file(instr_path) or '') or ''
  if instr ~= '' then
    local new_content
    if content == '' then
      new_content = instr
    else
      if not content:match('\n$') then content = content .. '\n' end
      new_content = content .. '\n' .. instr
    end
    local ok = utils.write_file(agents_md_path, new_content)
    if ok then
      -- Remove the standalone instructions file; Codex reads AGENTS.md directly
      pcall(vim.fn.delete, instr_path)
      logger.info('provider.codex.background', 'append_to_context: appended instructions into AGENTS.md and removed agent-instructions.md', {
        agents_md = agents_md_path
      })
    else
      logger.warn('provider.codex.background', 'append_to_context: failed to write AGENTS.md; keeping agent-instructions.md')
    end
  else
    logger.debug('provider.codex.background', 'append_to_context: no agent-instructions.md to inline')
  end
  return true
end

function M.launch_agent_pane(window_id, cwd, initial_text)
  if not window_id then return nil end
  local pane_id = tmux.split_window(window_id, 'h', 40)
  if not pane_id then return nil end
  if not tmux.send_to_pane(pane_id, 'cd ' .. vim.fn.shellescape(cwd)) then
    tmux.kill_pane(pane_id)
    return nil
  end

  local codex_home, prepare_err = prepare_codex_home()
  if not codex_home then
    logger.error('provider.codex.background', 'failed to prepare isolated CODEX_HOME', { error = prepare_err })
    tmux.kill_pane(pane_id)
    return nil
  end

  local task_file = codex_home .. '/task.txt'
  if not utils.write_file(task_file, initial_text or '') then
    remove_tree(codex_home)
    tmux.kill_pane(pane_id)
    return nil
  end
  pcall(uv.fs_chmod, task_file, 384)

  local cleanup = 'rm -rf -- ' .. vim.fn.shellescape(codex_home)
  local cmd = table.concat({
    '(',
    'trap ' .. vim.fn.shellescape(cleanup) .. ' EXIT;',
    'trap \'exit 129\' HUP INT TERM;',
    'export CODEX_HOME=' .. vim.fn.shellescape(codex_home) .. ';',
    (cfg.background_spawn or 'codex --full-auto') .. ' "$(cat ' .. vim.fn.shellescape(task_file) .. ')"',
    ')',
  }, ' ')
  if not tmux.send_to_pane(pane_id, cmd) then
    remove_tree(codex_home)
    tmux.kill_pane(pane_id)
    return nil
  end
  return pane_id
end

return M
