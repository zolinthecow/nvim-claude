local M = {}

-- Helper function to wait for LSP diagnostics from all attached clients
function M._await_lsp_diagnostics(files_to_check, timeout_ms)
  timeout_ms = timeout_ms or 3000
  
  -- Build tracking structure for all files
  local pending_files = {}
  for _, file_info in ipairs(files_to_check) do
    local file_path = file_info.path
    local bufnr = file_info.bufnr
    
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
      -- Make a minimal change to trigger LSP re-analysis
      -- This is more reliable than sending empty contentChanges
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if #lines > 0 then
        -- Touch the buffer by setting the same content
        -- This increments the version and triggers LSP analysis
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
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
  
  return success
end

-- Helper function to properly refresh buffer and wait for LSP updates
function M._refresh_buffer_diagnostics(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  
  -- Get current modification time of the file
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local old_mtime = vim.fn.getftime(file_path)
  
  -- Force buffer reload from disk
  vim.api.nvim_buf_call(bufnr, function()
    -- Clear existing diagnostics first to avoid stale data
    vim.diagnostic.reset(nil, bufnr)
    
    -- Reload the buffer from disk
    vim.cmd('silent! checktime')
    
    -- If file was modified externally, reload it
    if vim.fn.getftime(file_path) ~= old_mtime then
      vim.cmd('silent! edit!')
    end
  end)
  
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

function M.get_diagnostics(file_paths)
  local diagnostics = {}
  
  -- Handle both JSON strings and Lua tables
  if type(file_paths) == 'string' then
    local ok, parsed = pcall(vim.json.decode, file_paths)
    file_paths = ok and parsed or {}
  elseif file_paths == nil then
    file_paths = {}
  end
  
  -- Collect files to check
  local files_to_check = {}
  local temp_buffers = {} -- Track buffers we created
  
  if not file_paths or #file_paths == 0 then
    -- Get all loaded buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' then
          table.insert(files_to_check, {
            path = name,
            bufnr = buf
          })
        end
      end
    end
  else
    -- Get specific files
    for _, file_path in ipairs(file_paths) do
      -- Try exact path first
      local bufnr = vim.fn.bufnr(file_path)
      local full_path = file_path
      
      -- If not found, try as relative path from cwd
      if bufnr == -1 then
        full_path = vim.fn.getcwd() .. '/' .. file_path
        bufnr = vim.fn.bufnr(full_path)
      end
      
      -- If buffer doesn't exist, create it temporarily
      if bufnr == -1 then
        -- Check if file exists
        if vim.fn.filereadable(full_path) == 1 then
          -- Create buffer and load file
          bufnr = vim.fn.bufadd(full_path)
          vim.fn.bufload(bufnr)
          temp_buffers[bufnr] = true
          
          -- Trigger LSP attach by detecting filetype
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd 'filetype detect'
          end)
          
          -- Wait for LSP to attach
          vim.wait(500, function()
            return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
          end, 50)
        end
      end
      
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        table.insert(files_to_check, {
          path = vim.api.nvim_buf_get_name(bufnr),
          bufnr = bufnr
        })
      end
    end
  end
  
  -- Wait for LSP diagnostics from all files
  if #files_to_check > 0 then
    M._await_lsp_diagnostics(files_to_check, 3000)
  end
  
  -- Collect diagnostics after waiting
  for _, file_info in ipairs(files_to_check) do
    local bufnr = file_info.bufnr
    local diags = vim.diagnostic.get(bufnr)
    
    if #diags > 0 then
      local display_path = vim.fn.fnamemodify(file_info.path, ':~:.')
      diagnostics[display_path] = M._format_diagnostics(diags)
    end
  end
  
  -- Clean up temporary buffers
  for bufnr, _ in pairs(temp_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  
  return vim.json.encode(diagnostics)
end

function M.get_diagnostic_context(file_path, line)
  local bufnr = vim.fn.bufnr(file_path)
  local temp_buffer = false
  
  -- If buffer doesn't exist, create it temporarily
  if bufnr == -1 then
    if vim.fn.filereadable(file_path) == 0 then
      return vim.json.encode({error = 'File not found'})
    end
    
    bufnr = vim.fn.bufadd(file_path)
    vim.fn.bufload(bufnr)
    temp_buffer = true
    
    -- Trigger LSP attach by detecting filetype
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'filetype detect'
    end)
    
    -- Wait for LSP to attach
    vim.wait(500, function()
      return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
    end, 50)
  end
  
  -- Wait for LSP diagnostics
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    local files_to_check = {{
      path = vim.api.nvim_buf_get_name(bufnr),
      bufnr = bufnr
    }}
    M._await_lsp_diagnostics(files_to_check, 2000) -- Shorter timeout for single file
  end
  
  -- Get diagnostics for the specific line
  local diags = vim.diagnostic.get(bufnr, {lnum = line - 1})
  
  -- Get surrounding code context
  local start_line = math.max(0, line - 6)
  local end_line = line + 5
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  
  local result = vim.json.encode({
    diagnostics = M._format_diagnostics(diags),
    context = {
      lines = lines,
      start_line = start_line + 1,
      target_line = line,
    },
    filetype = vim.bo[bufnr].filetype,
  })
  
  -- Clean up temporary buffer if we created it
  if temp_buffer and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  
  return result
end

function M.get_diagnostic_summary()
  local summary = {
    total_errors = 0,
    total_warnings = 0,
    files_with_issues = {},
  }
  
  -- Collect all loaded buffers
  local files_to_check = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' then
        table.insert(files_to_check, {
          path = name,
          bufnr = buf
        })
      end
    end
  end
  
  -- Wait for LSP diagnostics from all files
  if #files_to_check > 0 then
    M._await_lsp_diagnostics(files_to_check, 3000)
  end
  
  -- Collect diagnostics after waiting
  for _, file_info in ipairs(files_to_check) do
    local bufnr = file_info.bufnr
    local diags = vim.diagnostic.get(bufnr)
    local file_errors = 0
    local file_warnings = 0
    
    for _, d in ipairs(diags) do
      if d.severity == vim.diagnostic.severity.ERROR then
        file_errors = file_errors + 1
        summary.total_errors = summary.total_errors + 1
      elseif d.severity == vim.diagnostic.severity.WARN then
        file_warnings = file_warnings + 1
        summary.total_warnings = summary.total_warnings + 1
      end
    end
    
    if file_errors > 0 or file_warnings > 0 then
      table.insert(summary.files_with_issues, {
        file = vim.fn.fnamemodify(file_info.path, ':~:.'),
        errors = file_errors,
        warnings = file_warnings,
      })
    end
  end
  
  return vim.json.encode(summary)
end

function M.get_session_diagnostics()
  local hooks = require('nvim-claude.hooks')
  local session_files = {}
  
  -- Get list of files edited in current session
  for file_path, _ in pairs(hooks.session_edited_files or {}) do
    table.insert(session_files, file_path)
  end
  
  -- Use existing get_diagnostics function with session files
  return M.get_diagnostics(session_files)
end

function M._format_diagnostics(diags)
  local formatted = {}
  for _, d in ipairs(diags) do
    table.insert(formatted, {
      line = d.lnum + 1,
      column = d.col + 1,
      severity = vim.diagnostic.severity[d.severity],
      message = d.message,
      source = d.source or 'lsp'
    })
  end
  return formatted
end

return M