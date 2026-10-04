local lazy = require('core.lazy')

local async = lazy('core.async')
local shutdown = lazy('core.shutdown')
local utils_math = lazy('core.utils.math')

local event = {}

local _augroup_created = false

local function ensure_augroup()
  if _augroup_created then return end
  _augroup_created = true
  vim.api.nvim_create_augroup('gitGroup', { clear = false })
end

local function augroup_disposer(group_name)
  local cleaned_up = false

  return function()
    if cleaned_up then return end
    cleaned_up = true
    pcall(vim.api.nvim_del_augroup_by_name, group_name)
  end
end

local function safe_async_void(func)
  local call_site_trace = debug.traceback('async function defined at:', 2)

  return function(...)
    local args = { ... }
    local argc = select('#', ...)

    local function error_handler(err)
      if shutdown.is_exiting() then return err end
      local error_trace = debug.traceback('', 2)
      local msg = string.format(
        '[Git] Async Error: %s\n\n--- Error Location ---\n%s\n--- Call Site ---\n%s',
        tostring(err),
        error_trace,
        call_site_trace
      )
      vim.schedule(function()
        vim.api.nvim_err_writeln(msg)
      end)
      return err
    end

    local function protected_func()
      xpcall(function()
        func(unpack(args, 1, argc))
      end, error_handler)
    end

    async.void(protected_func)()
  end
end

event.group = 'gitGroup'
event.async = safe_async_void
event.promisify = async.wrap
event.await = async.wrap(vim.schedule, 1)

function event.all(funcs, opts)
  opts = opts or {}
  if not opts.max_concurrent then opts.max_concurrent = 20 end
  return async.all(funcs, opts)
end

function event.on(event_names, callback)
  ensure_augroup()
  vim.api.nvim_create_autocmd(event_names, {
    group = event.group,
    callback = event.async(callback),
  })

  return event
end

function event.buffer_on(buffer, event_name, callback)
  ensure_augroup()
  local group = event_name
  if type(event_name) == 'table' then group = '::' .. table.concat(event_name, '::') end
  group = event.group .. '::' .. group .. '::' .. buffer.bufnr
  vim.api.nvim_create_augroup(group, { clear = true })
  vim.api.nvim_create_autocmd(event_name, {
    group = group,
    buffer = buffer.bufnr,
    callback = event.async(callback),
  })

  return event
end

function event.disposable_on(event_names, callback)
  ensure_augroup()
  local uuid = utils_math.uuid()
  local event_key = event_names
  if type(event_names) == 'table' then event_key = table.concat(event_names, '::') end
  local group_name = event.group .. '::disposable::' .. event_key .. '::' .. uuid

  vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd(event_names, {
    group = group_name,
    callback = callback,
  })

  return augroup_disposer(group_name)
end

function event.defer(fn, ms)
  local timer = vim.uv.new_timer()
  timer:start(ms, 0, function()
    if not timer:is_closing() then timer:close() end
    vim.schedule(fn)
  end)
  return timer
end

function event.custom_on(event_name, callback)
  local uuid = utils_math.uuid()
  local group_name = event.group .. '::custom::' .. event_name .. '::' .. uuid

  vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group_name,
    pattern = event_name,
    callback = event.async(callback),
  })

  return augroup_disposer(group_name)
end

function event.emit(event_name, data)
  vim.api.nvim_exec_autocmds({ 'User' }, {
    pattern = event_name,
    data = data,
  })
end

function event.debounce(fn, ms)
  local args, argc
  local cooldown = false
  local timer = nil

  local function close_timer()
    if timer and not timer:is_closing() then timer:close() end
    timer = nil
  end

  local debounced = function(...)
    args = { ... }
    argc = select('#', ...)

    if not cooldown then
      cooldown = true
      fn(...)
      close_timer()
      timer = vim.uv.new_timer()
      timer:start(ms, 0, function()
        close_timer()
        cooldown = false
      end)
      return
    end

    close_timer()
    timer = vim.uv.new_timer()
    timer:start(ms, 0, function()
      close_timer()
      cooldown = false
      vim.schedule(function()
        fn(unpack(args, 1, argc))
      end)
    end)
  end

  local cleanup = function()
    close_timer()
    cooldown = false
  end

  return debounced, cleanup
end

function event.debounce_async(fn, ms)
  return event.debounce(event.async(fn), ms)
end

function event.debounce_trailing(fn, ms)
  local args, argc
  local timer = nil

  local function close_timer()
    if timer and not timer:is_closing() then timer:close() end
    timer = nil
  end

  local debounced = function(...)
    args = { ... }
    argc = select('#', ...)

    close_timer()
    timer = vim.uv.new_timer()
    timer:start(ms, 0, function()
      close_timer()
      vim.schedule(function()
        fn(unpack(args, 1, argc))
      end)
    end)
  end

  local cleanup = function()
    close_timer()
  end

  return debounced, cleanup
end

function event.debounce_trailing_async(fn, ms)
  return event.debounce_trailing(event.async(fn), ms)
end

return event
