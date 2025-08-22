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
  
  -- Log which LSP servers we're expecting to respond
  local logger = require('nvim-claude.logger')
  local expected_clients = {}
  for file_path, info in pairs(pending_files) do
    expected_clients[vim.fn.fnamemodify(file_path, ':t')] = info.expected_sources
  end
  logger.debug('lsp-utils', 'Starting LSP diagnostic wait', {
    timeout_ms = timeout_ms,
    files = vim.tbl_count(pending_files),
    expected_clients = expected_clients
  })
  
  -- Set up autocmd to track diagnostic changes
  local diagnostic_received = false
  local client_response_times = {}  -- Track when each client responds
  local start_time = vim.loop.hrtime()
  
  local autocmd_id = vim.api.nvim_create_autocmd('DiagnosticChanged', {
    callback = function(args)
      local bufnr = args.buf
      local file_path = vim.api.nvim_buf_get_name(bufnr)
      
      if pending_files[file_path] then
        -- Mark that we received diagnostics for this buffer
        diagnostic_received = true
        
        -- Get all diagnostics for this buffer
        local diagnostics = args.data.diagnostics or {}
        
        local logger = require('nvim-claude.logger')
        logger.debug('lsp-utils', 'DiagnosticChanged event received', {
          file = vim.fn.fnamemodify(file_path, ':t'),
          buffer = bufnr,
          diagnostic_count = #diagnostics,
          elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
        })
        
        -- Track which sources have reported
        local sources_seen = {}
        local diagnostics_by_source = {}
        for _, diagnostic in ipairs(diagnostics) do
          local source = diagnostic.source or 'unknown'
          sources_seen[source] = true
          diagnostics_by_source[source] = (diagnostics_by_source[source] or 0) + 1
          
          -- Log when this client first responded
          if not client_response_times[source] then
            local elapsed_ms = (vim.loop.hrtime() - start_time) / 1e6
            client_response_times[source] = elapsed_ms
            logger.debug('lsp-utils', 'LSP server responded', {
              source = source,
              file = vim.fn.fnamemodify(file_path, ':t'),
              elapsed_ms = elapsed_ms,
              diagnostic_count = diagnostics_by_source[source]
            })
          end
        end
        
        -- Update received sources for this file
        pending_files[file_path].received_sources = sources_seen
        
        -- Log the breakdown by source
        if next(diagnostics_by_source) then
          logger.debug('lsp-utils', 'Diagnostics by source', {
            file = vim.fn.fnamemodify(file_path, ':t'),
            breakdown = diagnostics_by_source
          })
        end
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
    -- For TypeScript, we can't rely on diagnostic sources being set
    -- So we just check if diagnostics have been updated at all
    
    -- If we haven't received any diagnostic changes, keep waiting
    if not diagnostic_received then
      return false
    end
    
    -- For TypeScript files, consider it done once we get any diagnostic update
    -- since typescript-tools doesn't always set the source field
    for file_path, info in pairs(pending_files) do
      local is_typescript = file_path:match('%.tsx?$') or file_path:match('%.jsx?$')
      if is_typescript then
        -- For TypeScript, just check if we got a diagnostic event
        return true
      else
        -- For other languages, check sources as before
        for _, expected_source in ipairs(info.expected_sources) do
          if not info.received_sources[expected_source] then
            return false
          end
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
  
  local logger = require('nvim-claude.logger')
  
  -- Log whether we got all diagnostics or timed out
  if success then
    logger.debug('lsp-utils', 'All LSP servers reported diagnostics', {
      timeout_ms = timeout_ms,
      files_checked = vim.tbl_count(pending_files),
      client_response_times = client_response_times
    })
  else
    -- Check if we at least have some diagnostics
    local partial_success = has_some_diagnostics()
    
    -- Log detailed timeout information with per-file breakdown
    local missing_clients = {}
    local timeout_details = {}
    for file_path, info in pairs(pending_files) do
      local file_missing = {}
      for _, expected_source in ipairs(info.expected_sources) do
        if not info.received_sources[expected_source] then
          table.insert(missing_clients, expected_source)
          table.insert(file_missing, expected_source)
        end
      end
      if #file_missing > 0 then
        timeout_details[vim.fn.fnamemodify(file_path, ':t')] = {
          missing_sources = file_missing,
          expected_sources = info.expected_sources,
          received_sources = vim.tbl_keys(info.received_sources)
        }
      end
    end
    
    -- Log which specific LSP servers timed out
    logger.warn('lsp-utils', 'LSP server timeout details', {
      timeout_ms = timeout_ms,
      files_checked = vim.tbl_count(pending_files),
      timeout_details = timeout_details,
      client_response_times = client_response_times
    })
    
    if partial_success then
      logger.debug('lsp-utils', 'Partial LSP diagnostics received (timeout)', {
        timeout_ms = timeout_ms,
        files_checked = vim.tbl_count(pending_files),
        received_diagnostics = diagnostic_received,
        client_response_times = client_response_times,
        missing_clients = missing_clients
      })
      success = true
    else
      logger.warn('lsp-utils', 'LSP diagnostics timeout - no diagnostics received', {
        timeout_ms = timeout_ms,
        files_checked = vim.tbl_count(pending_files),
        missing_clients = missing_clients
      })
    end
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