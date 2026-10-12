local shutdown = {}

local exiting = false
local hooked = false

local function hook()
  local group = vim.api.nvim_create_augroup('TinShutdown', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    desc = 'Flag shutdown so in-flight async work can bail out',
    callback = shutdown.mark,
  })
  hooked = true
end

function shutdown.mark()
  exiting = true
end

function shutdown.is_exiting()
  if not hooked then hook() end

  return exiting
end

function shutdown.setup()
  hook()
end

function shutdown.reset()
  exiting = false
  hooked = false
end

return shutdown
