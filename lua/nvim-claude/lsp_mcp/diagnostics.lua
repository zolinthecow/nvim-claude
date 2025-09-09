-- Headless LSP diagnostics helpers (no inline-diff dependencies)

local M = {}

local logger = require('nvim-claude.logger')

local function format_diagnostics(diags)
  local out = {}
  for _, d in ipairs(diags or {}) do
    table.insert(out, {
      line = (d.lnum or 0) + 1,
      column = (d.col or 0) + 1,
      severity = vim.diagnostic.severity[d.severity] or 'INFO',
      message = d.message or '',
      source = d.source or 'lsp',
    })
  end
  return out
end

local function normalize_paths_arg(file_paths)
  -- Accept nil, table, or JSON string
  if file_paths == nil then return {} end
  if type(file_paths) == 'table' then return file_paths end
  if type(file_paths) == 'string' then
    local ok, parsed = pcall(vim.json.decode, file_paths)
    if ok and type(parsed) == 'table' then return parsed end
  end
  return {}
end

-- Create temp buffers for files, attach LSP, wait bounded, collect diagnostics, cleanup
function M.get_for_files(file_paths)
  local files = normalize_paths_arg(file_paths)

  local files_to_check = {}
  local temp_buffers = {}

  if not files or #files == 0 then
    -- Optional: try loaded buffers; headless instances typically have none
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and vim.fn.filereadable(name) == 1 then
          local tmp = vim.fn.bufadd(name)
          vim.fn.bufload(tmp)
          temp_buffers[tmp] = true
          table.insert(files_to_check, { path = name, bufnr = tmp })
        end
      end
    end
  else
    -- Create buffers for explicit files
    for _, path in ipairs(files) do
      if type(path) == 'string' and path ~= '' then
        local full = path
        if vim.fn.filereadable(full) ~= 1 then
          -- try relative to cwd
          local rel = vim.fn.getcwd() .. '/' .. path
          if vim.fn.filereadable(rel) == 1 then full = rel end
        end
        if vim.fn.filereadable(full) == 1 then
          local tmp = vim.fn.bufadd(full)
          vim.fn.bufload(tmp)
          temp_buffers[tmp] = true
          table.insert(files_to_check, { path = full, bufnr = tmp })
        end
      end
    end

    -- Trigger LSP attach for each buffer by simulating common events
    for _, info in ipairs(files_to_check) do
      local b = info.bufnr
      vim.cmd('buffer ' .. b)
      vim.api.nvim_buf_call(b, function()
        vim.cmd('filetype detect')
        pcall(vim.api.nvim_exec_autocmds, 'BufReadPost', { buffer = b })
        pcall(vim.api.nvim_exec_autocmds, 'BufEnter', { buffer = b })
        pcall(vim.api.nvim_exec_autocmds, 'InsertLeave', { buffer = b })
        pcall(vim.api.nvim_exec_autocmds, 'TextChanged', { buffer = b })
      end)
      -- Wait briefly for LSP to attach to this buffer
      vim.wait(500, function() return #vim.lsp.get_clients({ bufnr = b }) > 0 end, 50)
    end
  end

  -- Simple bounded wait like existing, to let diagnostics populate
  if #files_to_check > 0 then
    logger.debug('lsp_mcp.diagnostics', string.format('Starting diagnostic collection for %d buffers', #files_to_check))
    
    -- Collect all unique LSP clients across all buffers
    local all_clients = {}
    local client_names_by_buffer = {}
    for _, info in ipairs(files_to_check) do
      local clients = vim.lsp.get_clients({ bufnr = info.bufnr })
      client_names_by_buffer[info.bufnr] = {}
      for _, client in ipairs(clients) do
        all_clients[client.name] = true
        client_names_by_buffer[info.bufnr][client.name] = true
        logger.debug('lsp_mcp.diagnostics', string.format('Buffer %d (%s) has client: %s', 
          info.bufnr, vim.fn.fnamemodify(info.path, ':t'), client.name))
      end
    end
    
    local total_clients = vim.tbl_count(all_clients)
    logger.debug('lsp_mcp.diagnostics', string.format('Total unique LSP clients: %d', total_clients), {
      clients = vim.tbl_keys(all_clients)
    })
    
    -- Wait for diagnostics from all clients or timeout
    local waited = 0
    while waited < 3000 do
      -- Collect all diagnostic sources we've seen so far
      local seen_sources = {}
      local has_any_diagnostics = false
      
      for _, info in ipairs(files_to_check) do
        local diags = vim.diagnostic.get(info.bufnr)
        if diags and #diags > 0 then
          has_any_diagnostics = true
          for _, d in ipairs(diags) do
            if d.source then
              seen_sources[d.source] = true
            end
          end
        end
      end
      
      -- Check if we've heard from all clients
      -- Note: Some LSP client names don't match their diagnostic source names exactly
      -- Common mappings: typescript-tools -> tsserver, biome -> biome
      local mapped_sources = {}
      for source, _ in pairs(seen_sources) do
        mapped_sources[source] = true
        -- Normalize case and map common aliases
        local lower = string.lower(source)
        mapped_sources[lower] = true
        -- Handle common name mappings
        if lower == 'tsserver' then
          mapped_sources['typescript-tools'] = true
        elseif lower == 'typescript-tools' then
          mapped_sources['tsserver'] = true
        elseif lower == 'pyright' then
          mapped_sources['Pyright'] = true
          mapped_sources['pyright'] = true
        end
      end
      
      local all_responded = true
      local missing_clients = {}
      if total_clients > 0 then
        -- Check if we have diagnostics from all expected clients
        for client_name, _ in pairs(all_clients) do
          local client_key = client_name
          if mapped_sources[client_name] or mapped_sources[string.lower(client_name)] then
            -- ok
          else
          -- Some clients might not produce diagnostics if there are no issues
          -- So we check if either:
          -- 1. We've seen diagnostics from this source, OR
          -- 2. We've waited the full 3 seconds (gives TypeScript time in large projects)
            if waited < 3000 then
              all_responded = false
              table.insert(missing_clients, client_name)
            end
          end
        end
      end
      
      if waited % 200 == 0 then  -- Log every 200ms for less spam
        logger.debug('lsp_mcp.diagnostics', string.format('Wait %dms: sources seen: %s, missing: %s', 
          waited, vim.inspect(vim.tbl_keys(seen_sources)), vim.inspect(missing_clients)))
      end
      
      -- Stop if all clients responded or we've waited reasonable time
      if all_responded then
        logger.debug('lsp_mcp.diagnostics', 'All clients responded')
        break
      end
      
      vim.wait(100, function() return false end)
      waited = waited + 100
    end
    
    logger.debug('lsp_mcp.diagnostics', string.format('Finished waiting after %dms', waited))
  end

  -- Collect diagnostics
  local out = {}
  for _, info in ipairs(files_to_check) do
    local diags = vim.diagnostic.get(info.bufnr)
    local diag_details = {}
    if diags and #diags > 0 then
      for _, d in ipairs(diags) do
        table.insert(diag_details, {
          line = (d.lnum or 0) + 1,
          severity = vim.diagnostic.severity[d.severity] or 'INFO',
          message = d.message or '',
          source = d.source or 'unknown'
        })
      end
    end
    logger.debug('lsp_mcp.diagnostics', string.format('Buffer %d (%s): %d diagnostics found', 
      info.bufnr, vim.fn.fnamemodify(info.path, ':~:.'), #(diags or {})), 
      { diagnostics = diag_details })
    
    if diags and #diags > 0 then
      local display = vim.fn.fnamemodify(info.path, ':~:.')
      out[display] = format_diagnostics(diags)
    end
  end

  -- Cleanup
  for bufnr, _ in pairs(temp_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local clients = vim.lsp.get_clients({ bufnr = bufnr })
      for _, client in ipairs(clients) do
        pcall(vim.lsp.buf_detach_client, bufnr, client.id)
      end
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  return vim.json.encode(out)
end

function M.get_context(file_path, line)
  if not file_path or vim.fn.filereadable(file_path) == 0 then
    return vim.json.encode({ error = 'File not found' })
  end

  -- Always create a temp buffer (do not reuse existing)
  local tmp = vim.fn.bufadd('')
  local temp = true

  -- If a buffer already exists for this path, prefer its content and filetype
  local existing = vim.fn.bufnr(file_path)
  local ft = ''
  if existing ~= -1 then
    local content = vim.api.nvim_buf_get_lines(existing, 0, -1, false)
    vim.api.nvim_buf_set_lines(tmp, 0, -1, false, content)
    ft = vim.bo[existing].filetype
  else
    local content = vim.fn.readfile(file_path)
    vim.api.nvim_buf_set_lines(tmp, 0, -1, false, content)
  end

  local unique_name = file_path .. '.mcp-temp-' .. tmp
  vim.api.nvim_buf_set_name(tmp, unique_name)

  if ft ~= '' then
    vim.bo[tmp].filetype = ft
  else
    vim.api.nvim_buf_call(tmp, function() vim.cmd('filetype detect') end)
  end

  -- Wait briefly for LSP to attach/populate
  vim.wait(500, function() return #vim.lsp.get_clients({ bufnr = tmp }) > 0 end, 50)
  vim.wait(500, function() return false end)

  local lnum = math.max(0, (line or 1) - 1)
  local diags = vim.diagnostic.get(tmp, { lnum = lnum })

  local start_line = math.max(0, lnum - 5)
  local end_line = lnum + 6
  local lines = vim.api.nvim_buf_get_lines(tmp, start_line, end_line, false)

  local result = vim.json.encode({
    diagnostics = format_diagnostics(diags),
    context = {
      lines = lines,
      start_line = start_line + 1,
      target_line = lnum + 1,
    },
    filetype = vim.bo[tmp].filetype,
  })

  if temp and vim.api.nvim_buf_is_valid(tmp) then
    local clients = vim.lsp.get_clients({ bufnr = tmp })
    for _, client in ipairs(clients) do
      pcall(vim.lsp.buf_detach_client, tmp, client.id)
    end
    pcall(vim.api.nvim_buf_delete, tmp, { force = true })
  end

  return result
end

function M.get_summary()
  -- Build a summary over buffers we just checked (headless may have none)
  local files_to_check = {}
  local temp_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and vim.fn.filereadable(name) == 1 then
        local tmp = vim.fn.bufadd(name)
        vim.fn.bufload(tmp)
        temp_buffers[tmp] = true
        table.insert(files_to_check, { path = name, bufnr = tmp })
      end
    end
  end

  if #files_to_check > 0 then
    vim.wait(1000, function() return false end)
  end

  local summary = { total_errors = 0, total_warnings = 0, files_with_issues = {} }
  for _, info in ipairs(files_to_check) do
    local diags = vim.diagnostic.get(info.bufnr)
    local file_errors, file_warnings = 0, 0
    for _, d in ipairs(diags or {}) do
      if d.severity == vim.diagnostic.severity.ERROR then file_errors = file_errors + 1
      elseif d.severity == vim.diagnostic.severity.WARN then file_warnings = file_warnings + 1 end
    end
    summary.total_errors = summary.total_errors + file_errors
    summary.total_warnings = summary.total_warnings + file_warnings
    if file_errors > 0 or file_warnings > 0 then
      table.insert(summary.files_with_issues, {
        file = vim.fn.fnamemodify(info.path, ':~:.'),
        errors = file_errors,
        warnings = file_warnings,
      })
    end
  end

  for bufnr, _ in pairs(temp_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local clients = vim.lsp.get_clients({ bufnr = bufnr })
      for _, client in ipairs(clients) do
        pcall(vim.lsp.buf_detach_client, bufnr, client.id)
      end
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  return vim.json.encode(summary)
end

function M.get_session()
  local utils = require('nvim-claude.utils')
  local events = require('nvim-claude.events')
  local git_root = utils.get_project_root() or vim.fn.getcwd()
  local files = events.get_turn_files(git_root)
  return M.get_for_files(files)
end

return M
