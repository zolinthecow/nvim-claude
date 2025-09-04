-- Checkpoint façade: explicit public API over core

local core = require('nvim-claude.checkpoint.core')

local M = {}

-- Creation and listing
function M.create_checkpoint(prompt_text, git_root)
  return core.create_checkpoint(prompt_text, git_root)
end
function M.list_checkpoints() return core.list_checkpoints() end

-- State helpers (minimal)
function M.is_preview_mode(git_root)
  return core.is_preview_mode(git_root)
end
function M.get_status()
  local s = core.load_state() or {}
  return {
    mode = s.mode,
    preview_checkpoint = s.preview_checkpoint,
    original_ref = s.original_ref,
    preview_stash = s.preview_stash,
  }
end

-- Preview/restore flows
function M.exit_preview_mode(git_root) return core.exit_preview_mode(git_root) end
function M.accept_checkpoint(git_root) return core.accept_checkpoint(git_root) end
function M.restore_checkpoint(checkpoint_id, opts) return core.restore_checkpoint(checkpoint_id, opts) end

return M
