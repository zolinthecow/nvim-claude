-- Local OpenTelemetry listener for Codex CLI
-- Accepts OTLP/HTTP JSON log exports and mirrors relevant events into
-- nvim-claude's event pipeline (baseline creation, edited file tracking,
-- user prompt checkpoints).

local uv = vim.loop

local utils = require 'nvim-claude.utils'
local events = require 'nvim-claude.events'
local logger = require 'nvim-claude.logger'
local inline_diff = require 'nvim-claude.inline_diff'
local apply_patch_replay = require 'nvim-claude.agent_provider.providers.codex.apply_patch_replay'

local M = {}

local state = {
  server = nil,
  port = nil,
  autocmd_registered = false,
  default_git_root = utils.get_project_root(),
}

local function log_debug(message, data)
  logger.debug('codex_otel', message, data)
end

local function log_info(message, data)
  logger.info('codex_otel', message, data)
end

local function log_warn(message, data)
  logger.warn('codex_otel', message, data)
end

local function get_tool_arguments(attrs)
  if not attrs then
    return nil
  end

  local function normalize(value)
    if type(value) == 'string' and value ~= '' then
      return value
    end
    if type(value) == 'table' then
      if type(value.arguments) == 'string' and value.arguments ~= '' then
        return value.arguments
      end
      if type(value[1]) == 'string' then
        return table.concat(value, '\n')
      end
    end
    return nil
  end

  local candidates = {
    attrs.arguments,
    attrs.tool_arguments,
    attrs.body,
  }

  for _, candidate in ipairs(candidates) do
    local normalized = normalize(candidate)
    if normalized then
      return normalized
    end
  end

  return nil
end

local function decode_any_value(value)
  if type(value) ~= 'table' then
    return value
  end

  if value.stringValue ~= nil then
    return value.stringValue
  end
  if value.string_value ~= nil then
    return value.string_value
  end
  if value.boolValue ~= nil then
    return value.boolValue
  end
  if value.bool_value ~= nil then
    return value.bool_value
  end
  if value.intValue ~= nil then
    return tonumber(value.intValue)
  end
  if value.int_value ~= nil then
    return tonumber(value.int_value)
  end
  if value.doubleValue ~= nil then
    return value.doubleValue
  end
  if value.double_value ~= nil then
    return value.double_value
  end
  if value.bytesValue ~= nil then
    return value.bytesValue
  end
  if value.bytes_value ~= nil then
    return value.bytes_value
  end

  local array = value.arrayValue or value.array_value
  if type(array) == 'table' and type(array.values) == 'table' then
    local items = {}
    for _, item in ipairs(array.values) do
      table.insert(items, decode_any_value(item))
    end
    return items
  end

  local kv = value.kvlistValue or value.kvlist_value
  if type(kv) == 'table' and type(kv.values) == 'table' then
    local map = {}
    for _, entry in ipairs(kv.values) do
      if type(entry) == 'table' and entry.key then
        map[entry.key] = decode_any_value(entry.value)
      end
    end
    return map
  end

  return nil
end

local function attributes_to_map(list)
  local map = {}
  if type(list) ~= 'table' then
    return map
  end
  for _, attr in ipairs(list) do
    if type(attr) == 'table' then
      local key = attr.key or attr.name
      if key then
        map[key] = decode_any_value(attr.value)
      end
    end
  end
  return map
end

local function truncate_string(str, limit)
  if type(str) ~= 'string' then
    return str
  end
  local max = limit or 4000
  if #str <= max then
    return str
  end
  return str:sub(1, max) .. '…<truncated>'
end

local function sanitize_attrs(attrs)
  local copy = {}
  for k, v in pairs(attrs) do
    if type(v) == 'table' then
      copy[k] = vim.deepcopy(v)
    else
      copy[k] = v
    end
  end
  if type(copy.arguments) == 'string' then
    copy.arguments = truncate_string(copy.arguments, 4000)
  end
  if type(copy.output) == 'string' then
    copy.output = truncate_string(copy.output, 2000)
  end
  return copy
end

local function normalize_relative_path(path)
  if not path or path == '' then
    return nil
  end
  local trimmed = vim.trim(path)
  if trimmed == '' then
    return nil
  end
  trimmed = trimmed:gsub('^b?/', '')
  trimmed = trimmed:gsub('^%./', '')
  trimmed = trimmed:gsub('//+', '/')
  return trimmed ~= '' and trimmed or nil
end

local function normalize_git_root(path_hint)
  local checked = {}
  local function try(path)
    if not path or path == '' or checked[path] then
      return nil
    end
    checked[path] = true
    local stat = vim.loop.fs_stat(path)
    local dir = path
    if not stat then
      dir = vim.fn.fnamemodify(path, ':h')
    elseif stat.type ~= 'directory' then
      dir = vim.fn.fnamemodify(path, ':h')
    end
    if not dir or dir == '' then
      return nil
    end
    local cmd = string.format('cd %s && git rev-parse --show-toplevel 2>/dev/null', vim.fn.shellescape(dir))
    local out = vim.fn.system(cmd)
    if vim.v.shell_error == 0 and out and out ~= '' then
      return out:gsub('%s+$', '')
    end
    return nil
  end

  local candidates = {
    path_hint,
    state.default_git_root,
    utils.get_project_root(),
  }
  for _, candidate in ipairs(candidates) do
    local root = try(candidate)
    if root then
      return root
    end
  end
  return nil
end

local function read_baseline_file(git_root, relative_path)
  local ref = inline_diff.get_baseline_ref(git_root)
  if not ref then
    return nil
  end
  local quoted_root = vim.fn.shellescape(git_root)
  local quoted_rel = string.format("'%s'", relative_path:gsub("'", "'\\''"))
  local cmd = string.format('cd %s && git show %s:%s 2>/dev/null', quoted_root, ref, quoted_rel)
  local content, err = utils.exec(cmd)
  if err or not content or content == '' then
    return content
  end
  if content:match '^fatal:' or content:match '^error:' then
    return nil
  end
  return content
end

local function reconstruct_prior_from_update(git_root, abs_path, relative_path, operation)
  local hunks = operation.hunks or {}
  if #hunks == 0 then
    log_warn('update operation missing hunks', { git_root = git_root, path = relative_path })
    return nil
  end

  local current = utils.read_file(abs_path)
  if not current then
    log_warn('current file missing for reverse patch', { file = abs_path })
    return nil
  end

  local restored, err = apply_patch_replay.reconstruct_prior_content(current, hunks)
  if not restored then
    log_warn('reverse patch failed', {
      file = relative_path,
      error = err,
    })
    return nil
  end

  return restored
end

local function handle_apply_patch_operation(git_root, operation, attrs)
  log_debug('apply_patch_operation.start', { git_root = git_root, op_type = operation.type, path = operation.path, move_path = operation.move_path, call_id = attrs and attrs.call_id })
  local relative = normalize_relative_path(operation.move_path or operation.path)
  if not relative then
    log_warn('apply_patch operation missing path', { attrs = sanitize_attrs(attrs) })
    return false
  end

  local abs_path = git_root .. '/' .. relative
  local tracked = false
  local ok, is_tracked = pcall(events.is_edited_file, git_root, relative)
  if ok and is_tracked then
    tracked = true
  end

  local prior_content = nil
  if operation.type == 'update' then
    prior_content = reconstruct_prior_from_update(git_root, abs_path, relative, operation)
  elseif operation.type == 'add' then
    prior_content = ''
  elseif operation.type == 'delete' then
    prior_content = read_baseline_file(git_root, relative)
    if not prior_content then
      log_warn('baseline missing for delete operation', { file = relative })
    end
  else
    log_warn('unknown apply_patch operation type', { type = tostring(operation.type) })
    return false
  end

  if tracked then
    events.pre_tool_use(abs_path)
    events.post_tool_use(abs_path)
    log_info('apply_patch_operation.tracked', { file = relative, call_id = attrs and attrs.call_id })
    return true
  end

  if prior_content == nil and operation.type ~= 'add' then
    log_warn('unable to reconstruct prior content', {
      file = relative,
      type = operation.type,
    })
    events.post_tool_use(abs_path)
    return false
  end

  log_debug('apply_patch_operation.prior_content', {
    file = relative,
    op_type = operation.type,
    prior_len = prior_content and #prior_content or 0,
    prior_sha1 = prior_content and vim.fn.sha256(prior_content) or '',
    prior_preview = prior_content and prior_content:sub(1, 400) or '',
    call_id = attrs and attrs.call_id,
  })

  local opts = nil
  if prior_content ~= nil then
    opts = { prior_content = prior_content }
  end
  events.pre_tool_use(abs_path, opts)
  events.post_tool_use(abs_path)
  log_info('apply_patch_operation.completed', { file = relative, call_id = attrs and attrs.call_id, op_type = operation.type })
  return true
end

local function handle_tool_result(attrs)
  local tool = attrs['tool_name']
  if tool ~= 'apply_patch' then
    return
  end

  local git_root = normalize_git_root(attrs.cwd or utils.get_project_root())
  if not git_root or git_root == '' then
    log_warn('tool result without git root', { attrs = sanitize_attrs(attrs) })
    return
  end

  local patch = get_tool_arguments(attrs)
  local operations, parse_err = apply_patch_replay.parse_apply_patch_operations(patch)
  if not operations or #operations == 0 then
    log_warn('apply_patch result without operations', {
      git_root = git_root,
      call_id = attrs['call_id'],
      parse_error = parse_err,
    })
    return
  end

  local handled = 0
  for _, operation in ipairs(operations) do
    local ok = handle_apply_patch_operation(git_root, operation, attrs)
    if ok then
      handled = handled + 1
    end
  end

  log_info('apply_patch result processed', {
    git_root = git_root,
    call_id = attrs['call_id'],
    total_operations = #operations,
    handled_operations = handled,
  })
end

local function handle_user_prompt(attrs)
  local prompt = attrs['prompt']
  local git_root = utils.get_project_root()
  if not git_root or git_root == '' then
    return
  end
  if not prompt or prompt == '' then
    return
  end
  if prompt == '[REDACTED]' then
    prompt = 'Codex prompt (redacted)'
  end

  local original = vim.fn.getenv 'TARGET_FILE'
  vim.fn.setenv('TARGET_FILE', git_root)
  pcall(events.user_prompt_submit, prompt)
  if original and original ~= vim.NIL and original ~= '' then
    vim.fn.setenv('TARGET_FILE', original)
  else
    vim.fn.setenv('TARGET_FILE', '')
  end
  log_info('user prompt mirrored', {
    git_root = git_root,
    prompt_preview = prompt:sub(1, 120),
  })
end

local function process_log_record(attrs)
  local event_name = attrs['event.name']
  if not event_name then
    return
  end

  if event_name == 'codex.tool_result' then
    handle_tool_result(attrs)
  elseif event_name == 'codex.user_prompt' then
    handle_user_prompt(attrs)
  end
end

local function process_payload(payload)
  local resource_logs = payload.resourceLogs or payload.resource_logs
  if type(resource_logs) ~= 'table' then
    return
  end

  for _, resource in ipairs(resource_logs) do
    local resource_attrs = attributes_to_map(resource.resource and resource.resource.attributes)
    local scope_logs = resource.scopeLogs or resource.scope_logs
    if type(scope_logs) == 'table' then
      for _, scope in ipairs(scope_logs) do
        local log_records = scope.logRecords or scope.log_records
        if type(log_records) == 'table' then
          for _, record in ipairs(log_records) do
            local attrs = attributes_to_map(record.attributes)
            for key, value in pairs(resource_attrs) do
              if attrs[key] == nil then
                attrs[key] = value
              end
            end
            if record.body then
              attrs['body'] = decode_any_value(record.body)
            end
            process_log_record(attrs)
          end
        end
      end
    end
  end
end

-- Expose for external relay (daemon) to forward OTEL payloads into Neovim
function M.process_payload(payload)
  return process_payload(payload)
end

local function send_response(client, status_line)
  local response = status_line or 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'
  client:write(response, function()
    client:shutdown(function()
      client:close()
    end)
  end)
end

local function handle_client(client)
  local buffer = ''
  local headers_parsed = false
  local expected_length = nil
  local body_start = nil

  client:read_start(function(err, chunk)
    if err then
      logger.error('codex_otel', 'client read error', { error = err })
      client:close()
      return
    end

    if not chunk then
      client:close()
      return
    end

    buffer = buffer .. chunk

    if not headers_parsed then
      local header_end = buffer:find('\r\n\r\n', 1, true)
      if header_end then
        local header_blob = buffer:sub(1, header_end + 3)
        local request_line_end = header_blob:find('\r\n', 1, true)
        local request_line = header_blob:sub(1, request_line_end - 1)
        local method, path = request_line:match '^(%S+)%s+(%S+)'
        if method ~= 'POST' or path ~= '/v1/logs' then
          send_response(client, 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')
          return
        end
        local headers = {}
        for line in header_blob:sub(request_line_end + 2):gmatch '([^\r\n]+)' do
          local name, value = line:match '^([^:]+):%s*(.*)$'
          if name then
            headers[name:lower()] = value
          end
        end
        expected_length = tonumber(headers['content-length'] or '0')
        headers_parsed = true
        body_start = header_end + 4
      end
    end

    if headers_parsed and expected_length and body_start then
      local available = #buffer - (body_start - 1)
      if available >= expected_length then
        local body = buffer:sub(body_start, body_start + expected_length - 1)
        vim.schedule(function()
          local ok, decoded = pcall(vim.json.decode, body)
          if ok and decoded then
            local success, err = pcall(process_payload, decoded)
            if not success then
              logger.error('codex_otel', 'failed to process payload', { error = err })
            end
          else
            logger.error('codex_otel', 'json decode failed', { body = body:sub(1, 256) })
          end
        end)
        send_response(client)
      end
    end
  end)
end

local function stop_server()
  if state.server then
    pcall(function()
      state.server:close()
    end)
    state.server = nil
    state.port = nil
  end
end

local function ensure_autocmd()
  if state.autocmd_registered then
    return
  end
  state.autocmd_registered = true
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('NvimClaudeCodexOtel', { clear = true }),
    callback = function()
      stop_server()
    end,
  })
end

function M.ensure(port)
  if state.server and state.port == port then
    return true
  end

  stop_server()

  local server = uv.new_tcp()
  local ok, err = pcall(function()
    server:bind('127.0.0.1', port)
    server:listen(128, function(listen_err)
      if listen_err then
        logger.error('codex_otel', 'listener error', { error = listen_err })
        return
      end
      local client = uv.new_tcp()
      server:accept(client)
      handle_client(client)
    end)
  end)

  if not ok then
    logger.error('codex_otel', 'failed to start OTEL listener', { error = err, port = port })
    return false
  end

  state.server = server
  state.port = port
  ensure_autocmd()
  logger.info('codex_otel', 'Started OTLP listener', { port = port })
  return true
end

return M
