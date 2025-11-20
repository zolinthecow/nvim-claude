-- Codex provider configuration

local env_command = vim.env.NVIM_CLAUDE_CODEX_BIN
local default_command = env_command and env_command ~= '' and env_command or 'codex'

local M = {
  spawn_command = default_command,
  background_spawn = default_command .. ' --full-auto',
  pane_title = 'codex',
  process_pattern = 'codex',
  targeted_spawn_command = nil,
  targeted_pane_title = 'codex-targeted',
  targeted_split_direction = 'v',
  targeted_split_size = 35,
  targeted_init_delay_ms = 1500,
  otel_port = 4318,
  otel_environment = 'dev',
  otel_log_user_prompt = true,
}

function M.setup(opts)
  if type(opts) ~= 'table' then
    opts = {}
  end
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
  if type(opts.targeted_spawn_command) == 'string' and opts.targeted_spawn_command ~= '' then
    M.targeted_spawn_command = opts.targeted_spawn_command
  end
  if type(opts.targeted_pane_title) == 'string' and opts.targeted_pane_title ~= '' then
    M.targeted_pane_title = opts.targeted_pane_title
  end
  if opts.targeted_split_direction == 'h' or opts.targeted_split_direction == 'v' then
    M.targeted_split_direction = opts.targeted_split_direction
  end
  if type(opts.targeted_split_size) == 'number' and opts.targeted_split_size >= 5 and opts.targeted_split_size <= 95 then
    M.targeted_split_size = opts.targeted_split_size
  end
  if type(opts.targeted_init_delay_ms) == 'number' and opts.targeted_init_delay_ms >= 0 then
    M.targeted_init_delay_ms = opts.targeted_init_delay_ms
  end
  if type(opts.otel_port) == 'number' and opts.otel_port >= 1024 and opts.otel_port <= 65535 then
    M.otel_port = math.floor(opts.otel_port)
  end
  if type(opts.otel_environment) == 'string' and opts.otel_environment ~= '' then
    M.otel_environment = opts.otel_environment
  end
  if type(opts.otel_log_user_prompt) == 'boolean' then
    M.otel_log_user_prompt = opts.otel_log_user_prompt
  end
  -- Propagate to tmux config so detection and titles work
  local ok, utils = pcall(require, 'nvim-claude.utils')
  if ok and utils and utils.tmux and utils.tmux.config then
    utils.tmux.config.pane_title = M.pane_title
    utils.tmux.config.process_pattern = M.process_pattern
  end
end

return M
