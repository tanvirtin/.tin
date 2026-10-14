local keymap = require('core.keymap')

describe('keymap:', function()
  local original_set
  local calls

  before_each(function()
    calls = {}
    original_set = vim.keymap.set
    vim.keymap.set = function(mode, key, callback, opts)
      calls[#calls + 1] = { mode = mode, key = key, callback = callback, opts = opts }
    end
  end)

  after_each(function()
    vim.keymap.set = original_set
  end)

  describe('define', function()
    it('should define a key from "mode key" syntax', function()
      local cb = function() end
      keymap.define({ ['n <C-k>'] = cb })

      assert.are.equal(1, #calls)
      assert.are.equal('n', calls[1].mode)
      assert.are.equal('<C-k>', calls[1].key)
      assert.are.equal(cb, calls[1].callback)
    end)

    it('should define a key from a table config', function()
      local cb = function() end
      keymap.define({ { mode = 'n', key = '<C-j>', handler = cb, desc = 'down' } })

      assert.are.equal(1, #calls)
      assert.are.equal('n', calls[1].mode)
      assert.are.equal('<C-j>', calls[1].key)
      assert.are.equal(cb, calls[1].callback)
      assert.are.equal('down', calls[1].opts.desc)
    end)
  end)
end)
