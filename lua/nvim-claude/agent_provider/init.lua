-- Agent Provider façade: switchable integration layer (Claude-only for now)

local M = {}

local providers = {}
local current = nil

-- Load built-in providers lazily
local function load_provider(name)
  if providers[name] then return providers[name] end
  if name == 'claude' or name == 'claude_code' then
    local ok, impl = pcall(require, 'nvim-claude.agent_provider.providers.claude_code')
    if ok then
      providers['claude'] = impl
      providers['claude_code'] = impl
      return impl
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
  if not current or not current.install_hooks then return false end
  return current.install_hooks()
end

function M.uninstall_hooks()
  if not current or not current.uninstall_hooks then return false end
  return current.uninstall_hooks()
end

-- Chat transport (optional; not yet used by commands)
M.chat = {}

function M.chat.ensure_pane()
  if current and current.chat and current.chat.ensure_pane then
    return current.chat.ensure_pane()
  end
  return nil
end

function M.chat.send_text(text)
  if current and current.chat and current.chat.send_text then
    return current.chat.send_text(text)
  end
  return false
end

return M

