-- Codex provider configuration

local M = {
  spawn_command = 'codex',
  background_spawn = 'codex',
  pane_title = 'codex',
  process_pattern = 'codex',
}

function M.setup(opts)
  if type(opts) ~= 'table' then opts = {} end
  if type(opts.spawn_command) == 'string' and opts.spawn_command ~= '' then
    M.spawn_command = opts.spawn_command
  end
  if type(opts.background_spawn) == 'string' and opts.background_spawn ~= '' then
    M.background_spawn = opts.background_spawn
  end
  if type(opts.pane_title) == 'string' and opts.pane_title ~= '' then
    M.pane_title = opts.pane_title
  end
  if type(opts.process_pattern) == 'string' and opts.process_pattern ~= '' then
    M.process_pattern = opts.process_pattern
  end
  -- Propagate to tmux config so detection and titles work
  local ok, utils = pcall(require, 'nvim-claude.utils')
  if ok and utils and utils.tmux and utils.tmux.config then
    utils.tmux.config.pane_title = M.pane_title
    utils.tmux.config.process_pattern = M.process_pattern
  end
end

return M

