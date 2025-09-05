-- Claude provider configuration

local M = {
  spawn_command = 'claude',
  background_spawn = 'claude --dangerously-skip-permissions',
}

function M.setup(opts)
  if type(opts) ~= 'table' then return end
  if type(opts.spawn_command) == 'string' and opts.spawn_command ~= '' then
    M.spawn_command = opts.spawn_command
  end
  if type(opts.background_spawn) == 'string' and opts.background_spawn ~= '' then
    M.background_spawn = opts.background_spawn
  end
end

return M

