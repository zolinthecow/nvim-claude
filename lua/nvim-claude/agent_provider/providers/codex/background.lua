-- Codex provider: background agent helpers

local utils = require 'nvim-claude.utils'
local tmux = utils.tmux
local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local logger = require('nvim-claude.logger')

local M = {}

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
  -- Use shell-escaped cd to handle spaces/special chars in paths
  tmux.send_to_pane(pane_id, 'cd ' .. vim.fn.shellescape(cwd))
  -- Prepare isolated Codex HOME for the agent: copy user's ~/.codex then strip hooks
  local user_codex = vim.fn.expand('~/.codex')
  local agent_codex = cwd .. '/.codex'
  pcall(function()
    if vim.fn.isdirectory(user_codex) == 1 then
      -- Copy only if agent dir missing or empty
      if vim.fn.isdirectory(agent_codex) == 0 or vim.fn.glob(agent_codex .. '/*') == '' then
        utils.ensure_dir(agent_codex)
        utils.exec(string.format('cp -R %s/ %s 2>/dev/null', vim.fn.shellescape(user_codex), vim.fn.shellescape(agent_codex)))
      end
      -- Strip hooks from agent config.toml to prevent background hooks from running
      local cfg_path = agent_codex .. '/config.toml'
      if vim.fn.filereadable(cfg_path) == 1 then
        local content = utils.read_file(cfg_path) or ''
        if content ~= '' then
          local lines = {}
          for l in (content .. '\n'):gmatch('([^\n]*)\n') do table.insert(lines, l) end
          local start_idx, end_idx = nil, nil
          local in_hooks = false
          for i, l in ipairs(lines) do
            local is_header = l:match('^%s*%[') ~= nil
            local is_hooks_header = l:match('^%s*%[%[?hooks') ~= nil
            if is_header and is_hooks_header then
              if not in_hooks then start_idx = i; in_hooks = true end
            elseif is_header and in_hooks and (not is_hooks_header) then
              end_idx = i; break
            end
          end
          if in_hooks and not end_idx then end_idx = #lines + 1 end
          local new_content = content
          if start_idx then
            local before = table.concat(vim.list_slice(lines, 1, start_idx - 1), '\n')
            local after = table.concat(vim.list_slice(lines, end_idx, #lines), '\n')
            new_content = ''
            if before ~= '' then new_content = before .. '\n' end
            if after ~= '' then new_content = new_content .. after .. '\n' end
          end
          utils.write_file(cfg_path, new_content)
        end
      end
    end
  end)

  -- Prepare task text via a temp file to avoid quoting issues with special characters/newlines
  local task = initial_text or ''
  local task_file = cwd .. '/.codex-task.txt'
  utils.write_file(task_file, task)

  -- Isolate Codex config so background agents do NOT trigger hooks
  local codex_home = agent_codex
  utils.ensure_dir(codex_home)
  local env_prefix = 'CODEX_HOME=' .. vim.fn.shellescape(codex_home) .. ' '
  local spawn = (cfg.background_spawn or 'codex --full-auto')
  -- Pass the task as a single argv using command substitution; quoting preserves whitespace/newlines
  local cmd = env_prefix .. spawn .. ' ' .. '"$(cat ' .. vim.fn.shellescape(task_file) .. ')"'
  -- Use tmux buffer paste to avoid key interpretation/quoting issues
  tmux.send_text_to_pane(pane_id, cmd)
  return pane_id
end

return M
