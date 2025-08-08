-- Shared LSP diagnostic utilities
local M = {}

-- Helper function to wait for LSP diagnostics from all attached clients
function M.await_lsp_diagnostics(files_to_check, timeout_ms)
  timeout_ms = timeout_ms or 1500
  
  -- Track which buffers had inline diffs before we start
  local inline_diff = require('nvim-claude.inline-diff')
  local buffers_with_diffs = {}
  
  -- Build tracking structure for all files
  local pending_files = {}
  for _, file_info in ipairs(files_to_check) do
    local file_path = file_info.path
    local bufnr = file_info.bufnr
    
    -- Store inline diff state if present
    if inline_diff.active_diffs[bufnr] then
      buffers_with_diffs[bufnr] = {
        current_hunk = inline_diff.active_diffs[bufnr].current_hunk,
        file_path = file_path
      }
    end
    
    -- Get LSP clients attached to this buffer
    local clients = vim.lsp.get_clients({ bufnr = bufnr })
    local expected_sources = {}
    for _, client in ipairs(clients) do
      table.insert(expected_sources, client.name)
    end
    
    -- Only track if there are LSP clients
    if #expected_sources > 0 then
      pending_files[file_path] = {
        bufnr = bufnr,
        expected_sources = expected_sources,
        received_sources = {},
        initial_diagnostics = vim.diagnostic.get(bufnr)
      }
    end
  end
  
  -- If no files have LSP clients, return immediately
  if vim.tbl_isempty(pending_files) then
    return true
  end
  
  -- Set up autocmd to track diagnostic changes
  local diagnostic_received = false
  local autocmd_id = vim.api.nvim_create_autocmd('DiagnosticChanged', {
    callback = function(args)
      local bufnr = args.buf
      local file_path = vim.api.nvim_buf_get_name(bufnr)
      
      if pending_files[file_path] then
        -- Mark that we received diagnostics for this buffer
        diagnostic_received = true
        
        -- Get all diagnostics for this buffer
        local diagnostics = args.data.diagnostics or {}
        
        -- Track which sources have reported
        local sources_seen = {}
        for _, diagnostic in ipairs(diagnostics) do
          if diagnostic.source then
            sources_seen[diagnostic.source] = true
          end
        end
        
        -- Update received sources for this file
        pending_files[file_path].received_sources = sources_seen
      end
    end
  })
  
  -- Trigger refresh for all files
  for file_path, info in pairs(pending_files) do
    local bufnr = info.bufnr
    
    -- Force LSP to re-analyze by triggering a change event
    vim.api.nvim_buf_call(bufnr, function()
      -- Only touch the buffer if it's not already modified
      -- This avoids marking clean buffers as modified
      if not vim.bo[bufnr].modified then
        -- Make a minimal change to trigger LSP re-analysis
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        if #lines > 0 then
          -- Touch the buffer by setting the same content
          -- This increments the version and triggers LSP analysis
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          -- Mark as unmodified since we didn't actually change anything
          vim.bo[bufnr].modified = false
        end
      end
    end)
  end
  
  -- Wait for all LSPs to report or timeout
  local function all_lsps_reported()
    -- First check if we've received any diagnostic changes at all
    if not diagnostic_received then
      return false
    end
    
    for file_path, info in pairs(pending_files) do
      -- For each expected source, check if it has reported
      for _, expected_source in ipairs(info.expected_sources) do
        if not info.received_sources[expected_source] then
          -- This LSP hasn't reported yet
          -- However, if enough time has passed and we have some diagnostics, consider it done
          return false
        end
      end
    end
    return true
  end
  
  -- Also accept partial results after a shorter timeout
  local function has_some_diagnostics()
    if not diagnostic_received then
      return false
    end
    
    -- Check if at least one LSP per file has reported
    for file_path, info in pairs(pending_files) do
      local has_any = false
      for source, _ in pairs(info.received_sources) do
        has_any = true
        break
      end
      if not has_any then
        return false
      end
    end
    return true
  end
  
  -- Wait for diagnostics with fallback strategy
  local success = vim.wait(timeout_ms, all_lsps_reported, 50)
  
  -- If not all LSPs reported but we have some diagnostics, that's okay
  if not success then
    success = has_some_diagnostics()
  end
  
  -- Clean up autocmd
  vim.api.nvim_del_autocmd(autocmd_id)
  
  -- Restore inline diffs for any buffers that had them
  if not vim.tbl_isempty(buffers_with_diffs) then
    vim.defer_fn(function()
      local hooks = require('nvim-claude.hooks')
      local utils = require('nvim-claude.utils')
      local persistence = require('nvim-claude.inline-diff-persistence')
      local git_root = utils.get_project_root()
      
      if git_root and persistence.get_baseline_ref() then
        for bufnr, diff_info in pairs(buffers_with_diffs) do
          if vim.api.nvim_buf_is_valid(bufnr) then
            local file_path = diff_info.file_path
            local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
            
            -- Re-show the inline diff if file is still tracked
            if hooks.claude_edited_files[relative_path] then
              hooks.show_inline_diff_for_file(bufnr, relative_path, git_root, persistence.get_baseline_ref(), true)
              
              -- Restore hunk position
              if inline_diff.active_diffs[bufnr] then
                inline_diff.active_diffs[bufnr].current_hunk = diff_info.current_hunk
              end
            end
          end
        end
      end
    end, 100)
  end
  
  return success
end

-- Helper function to properly refresh buffer and wait for LSP updates
function M.refresh_buffer_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  
  -- Get current modification time of the file
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local old_mtime = vim.fn.getftime(file_path)
  
  -- Check if buffer has active inline diff and store its state
  local inline_diff = require('nvim-claude.inline-diff')
  local had_inline_diff = inline_diff.active_diffs[bufnr] ~= nil
  local diff_state = nil
  if had_inline_diff then
    -- Store current hunk position
    diff_state = {
      current_hunk = inline_diff.active_diffs[bufnr].current_hunk,
      cursor_pos = vim.api.nvim_win_get_cursor(0)
    }
  end
  
  -- Simply trigger LSP refresh without reloading from disk
  -- This avoids the E37 error and file modification issues
  vim.api.nvim_buf_call(bufnr, function()
    -- Clear existing diagnostics first to avoid stale data
    vim.diagnostic.reset(nil, bufnr)
    
    -- If file was modified externally, just checktime
    vim.cmd('silent! checktime')
  end)
  
  -- Restore inline diff if it was active
  if had_inline_diff then
    vim.defer_fn(function()
      local hooks = require('nvim-claude.hooks')
      local utils = require('nvim-claude.utils')
      local persistence = require('nvim-claude.inline-diff-persistence')
      
      -- Get git root and relative path
      local git_root = utils.get_project_root()
      if git_root then
        local relative_path = file_path:gsub('^' .. vim.pesc(git_root) .. '/', '')
        
        -- Re-show the inline diff
        if hooks.claude_edited_files[relative_path] and persistence.get_baseline_ref() then
          hooks.show_inline_diff_for_file(bufnr, relative_path, git_root, persistence.get_baseline_ref(), true)
          
          -- Restore cursor and hunk position
          if diff_state and inline_diff.active_diffs[bufnr] then
            inline_diff.active_diffs[bufnr].current_hunk = diff_state.current_hunk
            vim.api.nvim_win_set_cursor(0, diff_state.cursor_pos)
          end
        end
      end
    end, 50)
  end
  
  -- Wait for LSP clients to be ready
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients > 0 then
    -- Request fresh diagnostics from all LSP clients
    for _, client in ipairs(clients) do
      if client.supports_method('textDocument/diagnostic') then
        -- Request diagnostics refresh
        client.request('textDocument/diagnostic', {
          textDocument = vim.lsp.util.make_text_document_params(bufnr),
        }, nil, bufnr)
      end
    end
    
    -- Wait for diagnostics to be updated (with timeout)
    local max_wait = 500 -- milliseconds
    local waited = 0
    local interval = 50
    
    -- Store initial diagnostic version to detect changes
    local initial_version = vim.b[bufnr]._diagnostic_version or 0
    
    while waited < max_wait do
      vim.wait(interval)
      waited = waited + interval
      
      -- Check if diagnostics have been updated
      local current_version = vim.b[bufnr]._diagnostic_version or 0
      if current_version > initial_version then
        -- Diagnostics updated, wait a bit more for completeness
        vim.wait(50)
        break
      end
      
      -- Also break if we have any diagnostics (even if version didn't change)
      if #vim.diagnostic.get(bufnr) > 0 then
        vim.wait(50)
        break
      end
    end
  else
    -- No LSP clients, just wait a bit for potential attachment
    vim.wait(100)
  end
end

return M