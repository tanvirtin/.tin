local env = require('core.env')
local File = require('core.File')
local LogFormatter = require('core.console.LogFormatter')

local _file = File(string.format('/tmp/tin_%d.log', vim.fn.getpid()))

local debug_logger = {}

function debug_logger.is_enabled()
  return env.get('TIN_DEBUG') == true
end

function debug_logger.enable()
  env.set('TIN_DEBUG', true)
  _file:open('ab')
end

function debug_logger.disable()
  env.set('TIN_DEBUG', false)
  _file:close()
end

function debug_logger.append(msg, log_type, fn_source, fn_name)
  if not debug_logger.is_enabled() then return end
  local log = LogFormatter(msg):format(log_type, fn_source, fn_name):value()
  if not _file:is_open() then _file:open('ab') end
  _file:write({ log })
end

function debug_logger.info(msg)
  local call_info = debug.getinfo(2)
  debug_logger.append(msg, 'info', call_info.source, call_info.name)
end

function debug_logger.error(msg)
  local call_info = debug.getinfo(2)
  debug_logger.append(msg, 'error', call_info.source, call_info.name)
end

function debug_logger.warn(msg)
  local call_info = debug.getinfo(2)
  debug_logger.append(msg, 'warn', call_info.source, call_info.name)
end

function debug_logger.cleanup()
  if not debug_logger.is_enabled() then return end
  _file:close()
end

function debug_logger.get_path()
  return _file:get_path()
end

function debug_logger.open()
  if not debug_logger.is_enabled() then
    vim.notify('Debug mode is not enabled', vim.log.levels.WARN)
    return
  end
  vim.cmd('tabnew ' .. _file:get_path())
end

return debug_logger
