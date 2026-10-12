local shutdown = require('core.shutdown')

local eq = assert.are.same

describe('shutdown:', function()
  after_each(function()
    shutdown.reset()
  end)

  describe('is_exiting', function()
    it('is false while the editor is running', function()
      eq(false, shutdown.is_exiting())
    end)

    it('is true once mark is called', function()
      shutdown.mark()
      eq(true, shutdown.is_exiting())
    end)

    it('registers the exit hook on first use', function()
      shutdown.reset()
      local group = vim.api.nvim_create_augroup('TinShutdown', { clear = true })
      eq(0, #vim.api.nvim_get_autocmds({ group = group, event = 'VimLeavePre' }))

      shutdown.is_exiting()

      eq(1, #vim.api.nvim_get_autocmds({ group = group, event = 'VimLeavePre' }))
    end)
  end)

  describe('setup', function()
    it('registers a VimLeavePre hook that flags shutdown', function()
      shutdown.setup()
      local autocmds = vim.api.nvim_get_autocmds({ group = 'TinShutdown', event = 'VimLeavePre' })
      eq(1, #autocmds)

      eq(false, shutdown.is_exiting())
      autocmds[1].callback()
      eq(true, shutdown.is_exiting())
    end)

    it('does not stack duplicate hooks when called twice', function()
      shutdown.setup()
      shutdown.setup()
      local autocmds = vim.api.nvim_get_autocmds({ group = 'TinShutdown', event = 'VimLeavePre' })
      eq(1, #autocmds)
    end)
  end)
end)
