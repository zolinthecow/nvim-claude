local M = {}

function M.get_diagnostics(file_paths)
  local diagnostics = {}
  
  -- Handle both JSON strings and Lua tables
  if type(file_paths) == 'string' then
    local ok, parsed = pcall(vim.json.decode, file_paths)
    file_paths = ok and parsed or {}
  elseif file_paths == nil then
    file_paths = {}
  end
  
  if not file_paths or #file_paths == 0 then
    -- Get all diagnostics
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' then
          -- Refresh buffer from disk before getting diagnostics
          vim.api.nvim_buf_call(buf, function()
            vim.cmd 'checktime'
          end)
          -- Give LSP a moment to process any changes
          vim.wait(100)
          
          local diags = vim.diagnostic.get(buf)
          if #diags > 0 then
            diagnostics[vim.fn.fnamemodify(name, ':~:.')] = M._format_diagnostics(diags)
          end
        end
      end
    end
  else
    -- Get diagnostics for specific files
    for _, file_path in ipairs(file_paths) do
      -- Try exact path first
      local bufnr = vim.fn.bufnr(file_path)
      local full_path = file_path
      
      -- If not found, try as relative path from cwd
      if bufnr == -1 then
        full_path = vim.fn.getcwd() .. '/' .. file_path
        bufnr = vim.fn.bufnr(full_path)
      end
      
      -- If buffer doesn't exist, create it temporarily to get diagnostics
      local temp_buffer = false
      if bufnr == -1 then
        -- Create buffer and load file
        bufnr = vim.fn.bufadd(full_path)
        vim.fn.bufload(bufnr)
        temp_buffer = true
        -- Trigger LSP attach by detecting filetype
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd 'filetype detect'
        end)
        -- Wait for LSP to attach and process the file
        vim.wait(1000, function()
          return #vim.lsp.get_active_clients({ bufnr = bufnr }) > 0
        end, 50)
        -- Give LSP additional time to actually compute diagnostics
        vim.wait(300)
      else
        -- Buffer exists, refresh it from disk
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd 'checktime'
        end)
        -- Give LSP a moment to process any changes
        vim.wait(100)
      end
      
      if bufnr ~= -1 then
        local diags = vim.diagnostic.get(bufnr)
        if #diags > 0 then
          local display_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
          diagnostics[display_path] = M._format_diagnostics(diags)
        end
        
        -- Clean up temporary buffer if we created it
        if temp_buffer then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
    end
  end
  
  return vim.json.encode(diagnostics)
end

function M.get_diagnostic_context(file_path, line)
  local bufnr = vim.fn.bufnr(file_path)
  local temp_buffer = false
  
  -- If buffer doesn't exist, create it temporarily
  if bufnr == -1 then
    bufnr = vim.fn.bufadd(file_path)
    vim.fn.bufload(bufnr)
    temp_buffer = true
    -- Trigger LSP attach by detecting filetype
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'filetype detect'
    end)
    -- Wait for LSP to attach and process the file
    vim.wait(1000, function()
      return #vim.lsp.get_active_clients({ bufnr = bufnr }) > 0
    end, 50)
    -- Give LSP additional time to actually compute diagnostics
    vim.wait(300)
  else
    -- Buffer exists, refresh it from disk
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd 'checktime'
    end)
    -- Give LSP a moment to process any changes
    vim.wait(100)
  end
  
  if bufnr == -1 then
    return vim.json.encode({error = 'File not found'})
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
  if temp_buffer then
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
  
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' then
        -- Refresh buffer from disk before getting diagnostics
        vim.api.nvim_buf_call(buf, function()
          vim.cmd 'checktime'
        end)
        -- Give LSP a moment to process any changes
        vim.wait(100)
        
        local diags = vim.diagnostic.get(buf)
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
            file = vim.fn.fnamemodify(name, ':~:.'),
            errors = file_errors,
            warnings = file_warnings,
          })
        end
      end
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