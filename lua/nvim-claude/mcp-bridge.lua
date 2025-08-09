---@diagnostic disable: undefined-global
local M = {}
local lsp_utils = require('nvim-claude.lsp-utils')

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
    -- Get all loaded buffers but create temp copies
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and vim.fn.filereadable(name) == 1 then
          -- Create a temporary buffer copy
          local temp_bufnr = vim.fn.bufadd('')  -- Create unnamed buffer
          
          -- Copy content from original buffer
          local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, content)
          
          -- Set buffer name for diagnostics (add unique suffix to avoid conflicts)
          local unique_name = name .. '.mcp-temp-' .. temp_bufnr
          vim.api.nvim_buf_set_name(temp_bufnr, unique_name)
          
          -- Copy filetype from original buffer
          vim.bo[temp_bufnr].filetype = vim.bo[buf].filetype
          
          temp_buffers[temp_bufnr] = true
          
          table.insert(files_to_check, {
            path = name,
            bufnr = temp_bufnr
          })
        end
      end
    end
  else
    -- Get specific files - First pass: add all buffers
    local logger = require('nvim-claude.logger')
    local log_file_path = logger.get_mcp_debug_log_file()
    local log_file = io.open(log_file_path, 'a')
    
    for _, file_path in ipairs(file_paths) do
      if file_path then  -- Ensure file_path is not nil
        -- Determine full path
        local full_path = file_path
        if not file_path:match('^/') then
          -- Try as relative path from cwd
          local potential_path = vim.fn.getcwd() .. '/' .. file_path
          if vim.fn.filereadable(potential_path) == 1 then
            full_path = potential_path
          end
        end
        
        -- Check if file exists
        if vim.fn.filereadable(full_path) == 1 then
          -- Add buffer without switching to it yet
          local temp_bufnr = vim.fn.bufadd(full_path)
          vim.fn.bufload(temp_bufnr)  -- Load content
          
          if log_file then
            log_file:write(string.format('[%s] Processing file: %s\n', os.date('%Y-%m-%d %H:%M:%S'), full_path))
            local lines = vim.api.nvim_buf_get_lines(temp_bufnr, 0, -1, false)
            log_file:write(string.format('  Content lines: %d\n', #lines))
            log_file:write(string.format('  First line: %s\n', lines[1] or 'empty'))
          end
          
          temp_buffers[temp_bufnr] = true
          
          table.insert(files_to_check, {
            path = full_path,
            bufnr = temp_bufnr
          })
        end
      end  -- Close the if file_path then check
    end
    
    -- Second pass: trigger LSP for all buffers by visiting each once
    local current_buf = vim.api.nvim_get_current_buf()
    for _, file_info in ipairs(files_to_check) do
      local temp_bufnr = file_info.bufnr
      
      -- Switch to buffer to trigger textDocument/didOpen
      vim.cmd('buffer ' .. temp_bufnr)
      
      -- Trigger LSP attach by detecting filetype
      vim.api.nvim_buf_call(temp_bufnr, function()
        vim.cmd 'filetype detect'
        
        -- Debug: Log filetype
        local ft = vim.bo.filetype
        if log_file then
          log_file:write(string.format('  Filetype detected for %s: %s\n', file_info.path, ft or 'none'))
        end
        
        -- Trigger diagnostic push events for all files
        -- Many LSP servers use push model and only send diagnostics on these events
        vim.api.nvim_exec_autocmds('InsertLeave', { buffer = temp_bufnr })
        vim.api.nvim_exec_autocmds('TextChanged', { buffer = temp_bufnr })
      end)
    end
    
    -- Wait for LSP to attach to all buffers
    for _, file_info in ipairs(files_to_check) do
      local temp_bufnr = file_info.bufnr
      local wait_start = vim.loop.hrtime()
      
      local attached = vim.wait(500, function()
        return #vim.lsp.get_clients({ bufnr = temp_bufnr }) > 0
      end, 50)
      
      local wait_time_ms = (vim.loop.hrtime() - wait_start) / 1e6
      
      -- Debug: Check attached LSP clients
      local clients = vim.lsp.get_clients({ bufnr = temp_bufnr })
      if log_file then
        log_file:write(string.format('  LSP attach wait for buffer %d: %s in %.1fms\n', 
          temp_bufnr, attached and 'success' or 'timeout', wait_time_ms))
        log_file:write(string.format('  LSP clients attached to buffer %d: %d\n', temp_bufnr, #clients))
        for _, client in ipairs(clients) do
          log_file:write(string.format('    - %s (id: %d, capabilities: %s)\n', 
            client.name, client.id, 
            client.server_capabilities.diagnosticProvider and 'diagnostics' or 'no-diagnostics'))
        end
      end
    end
    
    if log_file then
      -- Check all available LSP clients in the system
      local all_clients = vim.lsp.get_clients()
      log_file:write(string.format('  Total LSP clients in system: %d\n', #all_clients))
      for _, client in ipairs(all_clients) do
        log_file:write(string.format('    - %s (id: %d)\n', client.name, client.id))
      end
      
      log_file:close()
    end
  end
  
  -- Wait for LSP diagnostics from all files
  local lsp_wait_success = false
  if #files_to_check > 0 then
    -- Use 3 second timeout for all files since we now trigger push events
    local timeout_ms = 3000
    lsp_wait_success = lsp_utils.await_lsp_diagnostics(files_to_check, timeout_ms)
  end
  
  -- Collect diagnostics after waiting
  local logger = require('nvim-claude.logger')
  local log_file_path = logger.get_mcp_debug_log_file()
  local log_file = io.open(log_file_path, 'a')
  if log_file then
    log_file:write(string.format('[%s] Collecting diagnostics from %d files (LSP wait %s)\n', 
      os.date('%Y-%m-%d %H:%M:%S'), 
      #files_to_check,
      lsp_wait_success and 'completed' or 'timed out'))
  end
  
  for _, file_info in ipairs(files_to_check) do
    local bufnr = file_info.bufnr
    local diags = vim.diagnostic.get(bufnr)
    
    if log_file then
      log_file:write(string.format('  File: %s, Buffer: %d, Diagnostics: %d\n', file_info.path, bufnr, #diags))
    end
    
    if #diags > 0 then
      local display_path = vim.fn.fnamemodify(file_info.path, ':~:.')
      diagnostics[display_path] = M._format_diagnostics(diags)
    end
  end
  
  if log_file then
    log_file:close()
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
  -- Check if file exists
  if vim.fn.filereadable(file_path) == 0 then
    return vim.json.encode({error = 'File not found'})
  end
  
  -- Always create a temporary buffer
  local temp_bufnr = vim.fn.bufadd('')  -- Create unnamed buffer
  local temp_buffer = true
  
  -- Check if there's an existing buffer to copy filetype from
  local existing_bufnr = vim.fn.bufnr(file_path)
  local filetype = ''
  if existing_bufnr ~= -1 then
    -- Copy content from existing buffer (might have unsaved changes)
    local content = vim.api.nvim_buf_get_lines(existing_bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, content)
    filetype = vim.bo[existing_bufnr].filetype
  else
    -- Read from file
    local content = vim.fn.readfile(file_path)
    vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, content)
  end
  
  -- Set buffer name for diagnostics
  local unique_name = file_path .. '.mcp-temp-' .. temp_bufnr
  vim.api.nvim_buf_set_name(temp_bufnr, unique_name)
  
  -- Set filetype
  if filetype ~= '' then
    vim.bo[temp_bufnr].filetype = filetype
  else
    vim.api.nvim_buf_call(temp_bufnr, function()
      vim.cmd 'filetype detect'
    end)
  end
  
  -- Wait for LSP to attach
  vim.wait(500, function()
    return #vim.lsp.get_clients({ bufnr = temp_bufnr }) > 0
  end, 50)
  
  local bufnr = temp_bufnr
  
  -- Wait for LSP diagnostics
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
    local files_to_check = {{
      path = vim.api.nvim_buf_get_name(bufnr),
      bufnr = bufnr
    }}
    lsp_utils.await_lsp_diagnostics(files_to_check, 3000) -- 3 second timeout for LSP analysis
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
  
  -- Collect all loaded buffers but use temp copies
  local files_to_check = {}
  local temp_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and vim.fn.filereadable(name) == 1 then
        -- Create a temporary buffer copy
        local temp_bufnr = vim.fn.bufadd('')
        
        -- Copy content from original buffer
        local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, content)
        
        -- Set buffer name and filetype (add unique suffix to avoid conflicts)
        local unique_name = name .. '.mcp-temp-' .. temp_bufnr
        vim.api.nvim_buf_set_name(temp_bufnr, unique_name)
        vim.bo[temp_bufnr].filetype = vim.bo[buf].filetype
        
        temp_buffers[temp_bufnr] = true
        
        table.insert(files_to_check, {
          path = name,
          bufnr = temp_bufnr
        })
      end
    end
  end
  
  -- Wait for LSP diagnostics from all files
  if #files_to_check > 0 then
    lsp_utils.await_lsp_diagnostics(files_to_check, 3000) -- 3 second timeout for LSP analysis
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
  
  -- Clean up temporary buffers
  for bufnr, _ in pairs(temp_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  
  return vim.json.encode(summary)
end

function M.get_session_diagnostics()
  local hooks = require('nvim-claude.hooks')
  local session_files = {}
  
  -- Get list of files edited in current session, filtering out deleted files
  for file_path, _ in pairs(hooks.session_edited_files or {}) do
    -- Only include files that still exist
    if vim.fn.filereadable(file_path) == 1 then
      table.insert(session_files, file_path)
    else
      -- File was deleted, remove from session tracking
      hooks.session_edited_files[file_path] = nil
    end
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

-- Async versions of the diagnostic functions that don't block the UI
-- These write results to a named pipe instead of returning them

function M.get_diagnostics_async(pipe_path, file_paths)
  -- Run asynchronously to avoid blocking UI
  vim.defer_fn(function()
    local result = M.get_diagnostics(file_paths)
    
    -- Write result to pipe
    local pipe = io.open(pipe_path, 'w')
    if pipe then
      pipe:write(result)
      pipe:close()
    else
      -- If we can't open the pipe, write an error
      local error_result = vim.json.encode({error = 'Failed to open pipe: ' .. pipe_path})
      -- Try to create a temp file as fallback
      local temp_file = pipe_path .. '.tmp'
      local f = io.open(temp_file, 'w')
      if f then
        f:write(error_result)
        f:close()
      end
    end
  end, 0)
end

function M.get_diagnostic_context_async(pipe_path, file_path, line)
  vim.defer_fn(function()
    local result = M.get_diagnostic_context(file_path, line)
    
    local pipe = io.open(pipe_path, 'w')
    if pipe then
      pipe:write(result)
      pipe:close()
    end
  end, 0)
end

function M.get_diagnostic_summary_async(pipe_path)
  vim.defer_fn(function()
    local result = M.get_diagnostic_summary()
    
    local pipe = io.open(pipe_path, 'w')
    if pipe then
      pipe:write(result)
      pipe:close()
    end
  end, 0)
end

function M.get_session_diagnostics_async(pipe_path)
  vim.defer_fn(function()
    local result = M.get_session_diagnostics()
    
    local pipe = io.open(pipe_path, 'w')
    if pipe then
      pipe:write(result)
      pipe:close()
    end
  end, 0)
end

return M