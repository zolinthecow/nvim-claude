-- Codex provider: chat transport via tmux

local cfg = require('nvim-claude.agent_provider.providers.codex.config')
local utils = require 'nvim-claude.utils'
local tmux = utils.tmux

local M = {}

local targeted_pane_id = nil

local function ensure_pane()
  local pane = tmux.find_chat_pane()
  if not pane then
    pane = tmux.create_pane(cfg.spawn_command or 'codex')
  end
  return pane
end

function M.ensure_pane()
  return ensure_pane()
end

function M.send_text(text)
  local pane = ensure_pane()
  if not pane then return false end
  return tmux.send_text_to_pane(pane, text)
end

local function spawn_targeted_pane(base_pane, initial_text)
  local pane_id = tmux.split_pane(base_pane, cfg.targeted_split_direction or 'v', cfg.targeted_split_size)
  if not pane_id then
    return nil
  end
  targeted_pane_id = pane_id
  if cfg.targeted_pane_title and cfg.targeted_pane_title ~= '' then
    tmux.set_pane_title(pane_id, cfg.targeted_pane_title)
  end

  local project_root = utils.get_project_root()
  if project_root and project_root ~= '' then
    tmux.send_to_pane(pane_id, 'cd ' .. vim.fn.shellescape(project_root))
  end

  local spawn_cmd = cfg.targeted_spawn_command or cfg.spawn_command or 'codex'
  if spawn_cmd and spawn_cmd ~= '' then
    tmux.send_to_pane(pane_id, spawn_cmd)
  end

  local delay = cfg.targeted_init_delay_ms or 800
  if initial_text and initial_text ~= '' then
    vim.defer_fn(function()
      if targeted_pane_id and tmux.pane_exists(targeted_pane_id) then
        tmux.send_text_to_pane(targeted_pane_id, initial_text)
      end
    end, delay)
  end
  return pane_id
end

function M.ensure_targeted_pane(initial_text)
  local base_pane = ensure_pane()
  if not base_pane then
    return nil
  end
  if targeted_pane_id and tmux.pane_exists(targeted_pane_id) then
    if initial_text and initial_text ~= '' then
      tmux.send_text_to_pane(targeted_pane_id, initial_text)
    end
    return targeted_pane_id
  end
  return spawn_targeted_pane(base_pane, initial_text)
end

function M.send_targeted_text(text)
  if not targeted_pane_id or not tmux.pane_exists(targeted_pane_id) then
    return false
  end
  return tmux.send_text_to_pane(targeted_pane_id, text)
end

function M.get_targeted_pane()
  if targeted_pane_id and tmux.pane_exists(targeted_pane_id) then
    return targeted_pane_id
  end
  return nil
end

return M
