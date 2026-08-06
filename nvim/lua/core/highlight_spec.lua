local highlight = require('core.highlight')
local mock = require('luassert.mock')

local eq = assert.are.same

describe('highlight:', function()
  before_each(function()
    vim.api = mock(vim.api, true)
  end)

  after_each(function()
    mock.revert(vim.api)
  end)

  describe('define', function()
    it('should produce highlight link command for string color', function()
      highlight.define('tingitTest', 'Normal')

      assert.stub(vim.api.nvim_exec2).was.called_with('highlight default link tingitTest Normal', {})
    end)

    it('should produce RGB highlight for table color', function()
      highlight.define('tingitTest', {
        fg = '#bb9af7',
        bg = '#3b4261',
      })

      assert
        .stub(vim.api.nvim_exec2).was
        .called_with('highlight tingitTest gui = NONE guifg = #bb9af7 guibg = #3b4261 ', {})
    end)

    it('should use NONE for missing fg/bg/gui fields', function()
      highlight.define('tingitTest', {})

      assert.stub(vim.api.nvim_exec2).was.called_with('highlight tingitTest gui = NONE guifg = NONE guibg = NONE ', {})
    end)

    it('should include gui value when provided', function()
      highlight.define('tingitTest', {
        fg = '#ffffff',
        gui = 'bold',
      })

      assert.stub(vim.api.nvim_exec2).was.called_with('highlight tingitTest gui = bold guifg = #ffffff guibg = NONE ', {})
    end)

    it('should include guisp when sp is provided', function()
      highlight.define('tingitTest', {
        fg = '#ffffff',
        sp = '#ff0000',
      })

      assert
        .stub(vim.api.nvim_exec2).was
        .called_with('highlight tingitTest gui = NONE guifg = #ffffff guibg = NONE guisp = #ff0000', {})
    end)

    it('should use default keyword when override is false', function()
      highlight.define('tingitTest', {
        fg = '#ffffff',
        override = false,
      })

      assert
        .stub(vim.api.nvim_exec2).was
        .called_with('highlight default tingitTest gui = NONE guifg = #ffffff guibg = NONE ', {})
    end)

    it('should not use default keyword when override is not false', function()
      highlight.define('tingitTest', {
        fg = '#ffffff',
      })

      assert.stub(vim.api.nvim_exec2).was.called_with('highlight tingitTest gui = NONE guifg = #ffffff guibg = NONE ', {})
    end)

    it('should call function and use result as table', function()
      highlight.define('tingitTest', function()
        return { fg = '#aabbcc', bg = '#112233' }
      end)

      assert
        .stub(vim.api.nvim_exec2).was
        .called_with('highlight tingitTest gui = NONE guifg = #aabbcc guibg = #112233 ', {})
    end)

    it('should return highlight module for chaining', function()
      local result = highlight.define('tingitTest', 'Normal')
      eq(highlight, result)
    end)

    it('should return highlight module for table color chaining', function()
      local result = highlight.define('tingitTest', { fg = '#fff' })
      eq(highlight, result)
    end)
  end)

  describe('register_module', function()
    local save_package, restore_packages = require('core.package_mock').create()
    local for_each_called

    before_each(function()
      for_each_called = false
      save_package('tingit.settings.hls')
      package.loaded['tingit.settings.hls'] = {
        for_each = function(_, callback)
          for_each_called = true
          callback('TestHl', { fg = '#fff' })
        end,
      }
    end)

    after_each(function()
      restore_packages()
    end)

    it('should call hls_setting:for_each', function()
      highlight.register_module()
      assert.is_true(for_each_called)
    end)

    it('should invoke dependency if provided', function()
      local called = false
      highlight.register_module(function()
        called = true
      end)

      assert.is_true(called)
    end)

    it('should return highlight module for chaining', function()
      local result = highlight.register_module()
      eq(highlight, result)
    end)
  end)
end)
