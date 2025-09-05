-- Agent Provider façade: switchable integration layer (Claude-only for now)

local M = {}

local providers = {}
local current = nil

-- Forward declaration for load_provider so ensure_current can call it
local load_provider

local function ensure_current()
  if current ~= nil then return current end
  local impl = load_provider and load_provider('claude') or nil
  current = impl
  return current
end

-- Load built-in providers lazily
load_provider = function(name)
  if providers[name] then return providers[name] end
  if name == 'claude' or name == 'claude_code' then
    -- Prefer new claude provider module; keep legacy alias for compatibility
    local ok, impl = pcall(require, 'nvim-claude.agent_provider.providers.claude')
    if ok then
      providers['claude'] = impl
      providers['claude_code'] = impl
      return impl
    end
    -- Legacy path fallback (should not trigger after refactor)
    local ok2, impl2 = pcall(require, 'nvim-claude.agent_provider.providers.claude_code')
    if ok2 then
      providers['claude'] = impl2
      providers['claude_code'] = impl2
      return impl2
    end
  end
  return nil
end

-- Public: setup the provider system
function M.setup(opts)
  opts = opts or {}
  local name = opts.provider or 'claude'
  local impl = load_provider(name)
  if not impl then
    -- Fallback to Claude if invalid name
    impl = load_provider('claude')
  end
  -- Pass provider-specific options to implementation if supported
  if impl and impl.setup then
    local provider_opts = opts[name] or {}
    pcall(impl.setup, provider_opts)
  end
  current = impl
end

-- Public: set provider explicitly (future-proof)
function M.set_provider(name)
  local impl = load_provider(name)
  if impl then current = impl end
  return current ~= nil
end

-- Public: get current provider name
function M.name()
  if current and current.name then return current.name end
  return 'claude'
end

-- Hook installation passthrough
function M.install_hooks()
  local impl = ensure_current()
  if not impl or not impl.install_hooks then return false end
  return impl.install_hooks()
end

function M.uninstall_hooks()
  local impl = ensure_current()
  if not impl or not impl.uninstall_hooks then return false end
  return impl.uninstall_hooks()
end

-- Chat transport (optional; not yet used by commands)
M.chat = {}

function M.chat.ensure_pane()
  local impl = ensure_current()
  if impl and impl.chat and impl.chat.ensure_pane then
    return impl.chat.ensure_pane()
  end
  return nil
end

function M.chat.send_text(text)
  local impl = ensure_current()
  if impl and impl.chat and impl.chat.send_text then
    return impl.chat.send_text(text)
  end
  return false
end

-- Background agent helpers (provider-specific launch)
M.background = {}

function M.background.launch_agent_pane(window_id, cwd, initial_text)
  local impl = ensure_current()
  if impl and impl.background and impl.background.launch_agent_pane then
    return impl.background.launch_agent_pane(window_id, cwd, initial_text)
  end
  return nil
end

function M.background.generate_window_name()
  local impl = ensure_current()
  if impl and impl.background and impl.background.generate_window_name then
    return impl.background.generate_window_name()
  end
  return 'agent-' .. (vim.loop and vim.loop.hrtime() or os.time())
end

function M.background.append_to_context(agent_dir)
  local impl = ensure_current()
  if impl and impl.background and impl.background.append_to_context then
    return impl.background.append_to_context(agent_dir)
  end
  return false
end

return M
