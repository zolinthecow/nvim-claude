-- Local OpenTelemetry listener for Codex CLI
-- Accepts OTLP/HTTP JSON log exports and mirrors relevant events into
-- nvim-claude's event pipeline (baseline creation, edited file tracking,
-- user prompt checkpoints).

local uv = vim.loop

local utils = require('nvim-claude.utils')
local events = require('nvim-claude.events')
local logger = require('nvim-claude.logger')
local inline_diff = require('nvim-claude.inline_diff')

local M = {}

local state = {
  server = nil,
  port = nil,
  pending_calls = {},
  baseline_initialized = {},
  last_status = {},
  autocmd_registered = false,
  default_git_root = utils.get_project_root(),
}

local tracked_tools = {
  local_shell = true,
  apply_patch = true,
  unified_exec = true,
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

local function snapshot_count(snapshot)
  local count = 0
  if snapshot then
    for _ in pairs(snapshot) do
      count = count + 1
    end
  end
  return count
end

local function log_snapshot(stage, git_root, context, snapshot)
  local data = {
    git_root = git_root,
    count = snapshot_count(snapshot),
    files = snapshot,
  }
  if context then
    for k, v in pairs(context) do
      data[k] = v
    end
  end
  log_debug('git status snapshot (' .. stage .. ')', data)
  if stage == 'decision' then
    pcall(function()
      vim.fn.writefile({ vim.fn.json_encode(data) }, '/tmp/nvim-claude-codex-otel-before.json')
    end)
  elseif stage == 'result-after' then
    pcall(function()
      vim.fn.writefile({ vim.fn.json_encode(data) }, '/tmp/nvim-claude-codex-otel-after.json')
    end)
  end
end

local function decode_any_value(value)
  if type(value) ~= 'table' then
    return value
  end

  if value.stringValue ~= nil then return value.stringValue end
  if value.string_value ~= nil then return value.string_value end
  if value.boolValue ~= nil then return value.boolValue end
  if value.bool_value ~= nil then return value.bool_value end
  if value.intValue ~= nil then return tonumber(value.intValue) end
  if value.int_value ~= nil then return tonumber(value.int_value) end
  if value.doubleValue ~= nil then return value.doubleValue end
  if value.double_value ~= nil then return value.double_value end
  if value.bytesValue ~= nil then return value.bytesValue end
  if value.bytes_value ~= nil then return value.bytes_value end

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
  if type(list) ~= 'table' then return map end
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
  if type(str) ~= 'string' then return str end
  local max = limit or 4000
  if #str <= max then return str end
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
  if not path or path == '' then return nil end
  local trimmed = vim.trim(path)
  if trimmed == '' then return nil end
  trimmed = trimmed:gsub('^b?/', '')
  trimmed = trimmed:gsub('^%./', '')
  trimmed = trimmed:gsub('//+', '/')
  return trimmed ~= '' and trimmed or nil
end

local function parse_apply_patch_paths(patch)
  if type(patch) ~= 'string' or patch == '' then return {} end
  local dedup = {}
  local targets = {}

  local function add_path(rel)
    local normalized = normalize_relative_path(rel)
    if normalized and not dedup[normalized] then
      dedup[normalized] = true
      table.insert(targets, normalized)
    end
  end

  for line in patch:gmatch('[^\n]+') do
    local update = line:match('^%*%*%*%s+[Uu]pdate File:%s+(.+)$')
    if update then
      add_path(update)
    else
      local add_file = line:match('^%*%*%*%s+[Aa]dd File:%s+(.+)$')
      if add_file then
        add_path(add_file)
      else
        local delete = line:match('^%*%*%*%s+[Dd]elete File:%s+(.+)$')
        if delete then
          add_path(delete)
        else
          local move_from, move_to = line:match('^%*%*%*%s+[Mm]ove File:%s+(.+)%s+%-%>%s+(.+)$')
          if move_from and move_to then
            add_path(move_from)
            add_path(move_to)
          end
        end
      end
    end
  end

  return targets
end

local function resolve_abs_paths(git_root, rel_paths)
  local abs = {}
  if not rel_paths then return abs end
  for _, rel in ipairs(rel_paths) do
    local normalized = normalize_relative_path(rel)
    if normalized then
      local combined = git_root .. '/' .. normalized
      local full = vim.fn.fnamemodify(combined, ':p')
      table.insert(abs, full)
    end
  end
  return abs
end

local function collect_apply_patch_targets(git_root, attrs)
  if not git_root or git_root == '' then return {} end
  if not attrs then return {} end
  local patch = attrs.arguments
  if type(patch) ~= 'string' or patch == '' then return {} end
  local rel_targets = parse_apply_patch_paths(patch)
  if not rel_targets or #rel_targets == 0 then
    return {}
  end
  return resolve_abs_paths(git_root, rel_targets)
end

local function log_tool_event(stage, attrs, extra)
  local data = extra or {}
  data.attrs = sanitize_attrs(attrs)
  log_info('tool ' .. stage, data)
end

local function normalize_git_root(path_hint)
  local checked = {}
  local function try(path)
    if not path or path == '' or checked[path] then return nil end
    checked[path] = true
    local stat = vim.loop.fs_stat(path)
    local dir = path
    if not stat then
      dir = vim.fn.fnamemodify(path, ':h')
    elseif stat.type ~= 'directory' then
      dir = vim.fn.fnamemodify(path, ':h')
    end
    if not dir or dir == '' then return nil end
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

local function git_status_snapshot(git_root)
  local cmd = string.format('cd %s && git status --porcelain=1 -z', vim.fn.shellescape(git_root))
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    log_warn('git status failed', { git_root = git_root, stderr = output })
    return {}
  end
  local entries = vim.split(output, '\0')
  local snapshot = {}
  for _, entry in ipairs(entries) do
    if entry and entry ~= '' then
      local status = entry:sub(1, 2)
      local path = vim.trim(entry:sub(4))
      if path ~= '' then
        snapshot[path] = status
      end
    end
  end
  log_debug('git status run', {
    git_root = git_root,
    raw_len = #output,
    entry_count = vim.tbl_count(snapshot),
    sample = table.concat(vim.list_slice(entries, 1, math.min(5, #entries)), '\\n'),
  })
  return snapshot
end

local function diff_snapshots(before, after)
  local delta = {}
  before = before or {}
  after = after or {}

  for path, status in pairs(after) do
    if before[path] ~= status then
      delta[path] = status
    end
  end

  for path in pairs(before) do
    if not after[path] then
      delta[path] = ' D'
    end
  end

  return delta
end

local function mark_changed_files(git_root, delta)
  if not git_root or git_root == '' then return end
  if not delta then return end
  local files = {}
  for path in pairs(delta) do
    if path and path ~= '' then
      local abs = git_root .. '/' .. path
      events.post_tool_use(abs)
      table.insert(files, abs)
    end
  end
  if #files > 0 then
    log_info('marked edited files', { git_root = git_root, count = #files, files = files })
  end
end

local function ensure_baseline(git_root, conversation_id, context)
  local normalized = normalize_git_root(git_root)
  if not normalized then
    log_warn('baseline skipped (git root unresolved)', {
      requested_root = git_root,
      conversation = conversation_id,
      context = context,
    })
    return nil
  end

  local key = conversation_id or normalized
  local already_initialized = key and state.baseline_initialized[key] or false
  local had_ref = inline_diff.get_baseline_ref(normalized) ~= nil

  local ok = events.pre_tool_use(normalized)
  if key then
    state.baseline_initialized[key] = true
  end
  log_info('baseline ensured', {
    git_root = normalized,
    conversation = conversation_id,
    already_initialized = already_initialized,
    baseline_preexisting = had_ref,
    ensure_result = ok ~= false,
    context = context,
  })
  return normalized
end

local function handle_tool_decision(attrs)
  local tool = attrs['tool_name']
  if not tool or not tracked_tools[tool] then return end
  local decision = attrs['decision']
  if decision ~= 'approved' and decision ~= 'approved_for_session' then return end
  local call_id = attrs['call_id']
  if not call_id or call_id == '' then return end

  local git_root = normalize_git_root(attrs.cwd or utils.get_project_root())
  if not git_root then
    log_warn('tool decision without git root', { call_id = call_id, tool = tool, attrs = sanitize_attrs(attrs) })
    return
  end

  log_tool_event('decision', attrs, {
    call_id = call_id,
    tool = tool,
    git_root = git_root,
    cwd_attr = attrs.cwd,
    baseline_exists = inline_diff.get_baseline_ref(git_root) ~= nil,
  })

  local entry = {
    git_root = git_root,
    before = nil,
    targets = {},
    tool = tool,
  }
  if tool ~= 'apply_patch' then
    local snapshot = git_status_snapshot(git_root)
    entry.before = snapshot
    log_snapshot('decision', git_root, {
      call_id = call_id,
      tool = tool,
    }, snapshot)
  end
  state.pending_calls[call_id] = entry

  ensure_baseline(git_root, attrs['conversation.id'], { call_id = call_id, tool = tool })

  if tool == 'apply_patch' then
    local abs_targets = collect_apply_patch_targets(git_root, attrs)
    entry.targets = abs_targets
    if abs_targets and #abs_targets > 0 then
      for _, abs in ipairs(abs_targets) do
        events.pre_tool_use(abs)
      end
      log_info('apply_patch targets tracked', {
        call_id = call_id,
        git_root = git_root,
        count = #abs_targets,
        targets = abs_targets,
      })
    else
      log_warn('apply_patch decision without targets', {
        call_id = call_id,
        git_root = git_root,
      })
    end
  end

  log_debug('tool decision processed', {
    tool = tool,
    call_id = call_id,
    git_root = git_root,
    decision = decision,
    pending_files = entry.before and vim.tbl_count(entry.before) or 0,
  })
end

local function handle_tool_result(attrs)
  local call_id = attrs['call_id']
  local tool = attrs['tool_name']
  if tool and not tracked_tools[tool] then return end

  local pending = call_id and state.pending_calls[call_id] or nil
  local git_root = (pending and pending.git_root) or normalize_git_root(attrs.cwd or utils.get_project_root())
  if not git_root or git_root == '' then return end

  local resolved_tool = tool or (pending and pending.tool)
  log_tool_event('result', attrs, {
    call_id = call_id,
    tool = resolved_tool,
    git_root = git_root,
    cwd_attr = attrs.cwd,
    success = attrs.success,
  })

  local pending_tool = (pending and pending.tool) or tool
  if pending_tool == 'apply_patch' then
    local target_paths = {}
    if pending and pending.targets and #pending.targets > 0 then
      target_paths = pending.targets
    else
      target_paths = collect_apply_patch_targets(git_root, attrs)
      if target_paths and #target_paths > 0 then
        -- We missed pre_tool_use (no decision), so ensure baselines now.
        for _, abs in ipairs(target_paths) do
          events.pre_tool_use(abs)
        end
      end
    end

    if target_paths and #target_paths > 0 then
      for _, abs in ipairs(target_paths) do
        events.post_tool_use(abs)
      end
      log_info('apply_patch targets marked', {
        call_id = call_id,
        git_root = git_root,
        count = #target_paths,
        paths = target_paths,
      })
    else
      log_warn('apply_patch result without targets', {
        call_id = call_id,
        git_root = git_root,
      })
    end
    if call_id then
      state.pending_calls[call_id] = nil
    end
    return
  end

  local after = git_status_snapshot(git_root)
  log_snapshot('result-after', git_root, {
    call_id = call_id,
    tool = resolved_tool,
  }, after)
  local before = pending and pending.before or state.last_status[git_root] or {}
  log_snapshot('result-before', git_root, {
    call_id = call_id,
    tool = resolved_tool,
  }, before)
  local delta = diff_snapshots(before, after)
  if next(delta) then
    mark_changed_files(git_root, delta)
    log_info('tool result delta', {
      call_id = call_id,
      tool = resolved_tool,
      git_root = git_root,
      changed = delta,
    })
  else
    log_debug('tool result had no diff', {
      call_id = call_id,
      tool = resolved_tool,
      git_root = git_root,
    })
  end

  state.last_status[git_root] = after
  if call_id then
    state.pending_calls[call_id] = nil
  end
end

local function handle_user_prompt(attrs)
  local prompt = attrs['prompt']
  local git_root = utils.get_project_root()
  if not git_root or git_root == '' then return end
  if not prompt or prompt == '' then return end
  if prompt == '[REDACTED]' then
    prompt = 'Codex prompt (redacted)'
  end

  local original = vim.fn.getenv('TARGET_FILE')
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
  if not event_name then return end

  if event_name == 'codex.tool_decision' then
    handle_tool_decision(attrs)
  elseif event_name == 'codex.tool_result' then
    handle_tool_result(attrs)
  elseif event_name == 'codex.user_prompt' then
    handle_user_prompt(attrs)
  end
end

local function process_payload(payload)
  local resource_logs = payload.resourceLogs or payload.resource_logs
  if type(resource_logs) ~= 'table' then return end

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
        local method, path = request_line:match('^(%S+)%s+(%S+)')
        if method ~= 'POST' or path ~= '/v1/logs' then
          send_response(client, 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n')
          return
        end
        local headers = {}
        for line in header_blob:sub(request_line_end + 2):gmatch('([^\r\n]+)') do
          local name, value = line:match('^([^:]+):%s*(.*)$')
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
    state.pending_calls = {}
    state.baseline_initialized = {}
    state.last_status = {}
  end
end

local function ensure_autocmd()
  if state.autocmd_registered then return end
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
