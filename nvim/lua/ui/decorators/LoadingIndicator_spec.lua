local eq = assert.are.same

describe('LoadingIndicator:', function()
  local LoadingIndicator

  before_each(function()
    LoadingIndicator = require('ui.decorators.LoadingIndicator')
  end)

  describe('constructor', function()
    it('should initialize with inactive state', function()
      local indicator = LoadingIndicator()
      assert.is_false(indicator:is_active())
    end)
  end)

  describe('start', function()
    it('should set active state to true', function()
      local indicator = LoadingIndicator()
      indicator:start()
      assert.is_true(indicator:is_active())
      indicator:stop()
    end)

    it('should not restart if already active', function()
      local indicator = LoadingIndicator()
      indicator:start()
      local first_timer = indicator._timer
      indicator:start()
      eq(first_timer, indicator._timer)
      indicator:stop()
    end)
  end)

  describe('stop', function()
    it('should set active state to false', function()
      local indicator = LoadingIndicator()
      indicator:start()
      indicator:stop()
      assert.is_false(indicator:is_active())
    end)

    it('should clean up timer', function()
      local indicator = LoadingIndicator()
      indicator:start()
      indicator:stop()
      assert.is_nil(indicator._timer)
    end)

    it('should be safe to call when not active', function()
      local indicator = LoadingIndicator()
      indicator:stop()
      assert.is_false(indicator:is_active())
    end)

    it('should be safe to call twice', function()
      local indicator = LoadingIndicator()
      indicator:start()
      indicator:stop()
      indicator:stop()
      assert.is_false(indicator:is_active())
      assert.is_nil(indicator._timer)
    end)
  end)

  describe('is_active', function()
    it('should return false initially', function()
      local indicator = LoadingIndicator()
      assert.is_false(indicator:is_active())
    end)

    it('should return true after start', function()
      local indicator = LoadingIndicator()
      indicator:start()
      assert.is_true(indicator:is_active())
      indicator:stop()
    end)

    it('should return false after stop', function()
      local indicator = LoadingIndicator()
      indicator:start()
      indicator:stop()
      assert.is_false(indicator:is_active())
    end)
  end)

  describe('render', function()
    it('should not error when element is nil', function()
      local indicator = LoadingIndicator()
      assert.has_no.errors(function()
        indicator:render(nil)
      end)
    end)

    it('should not touch an invalid element', function()
      local indicator = LoadingIndicator()
      local calls = {}
      local mock_element = {
        is_valid = function()
          return false
        end,
        clear_extmark_highlights = function()
          calls[#calls + 1] = 'clear_extmark_highlights'
        end,
        get_height = function()
          calls[#calls + 1] = 'get_height'
          return 10
        end,
        get_width = function()
          calls[#calls + 1] = 'get_width'
          return 40
        end,
        set_lines = function()
          calls[#calls + 1] = 'set_lines'
        end,
        place_extmark_highlight = function()
          calls[#calls + 1] = 'place_extmark_highlight'
        end,
      }

      indicator:render(mock_element)

      eq({}, calls)
    end)

    it('should set lines on valid element', function()
      local indicator = LoadingIndicator()
      local set_lines_data = nil
      local mock_element = {
        is_valid = function()
          return true
        end,
        clear_extmark_highlights = function() end,
        get_height = function()
          return 10
        end,
        get_width = function()
          return 40
        end,
        set_lines = function(_, lines)
          set_lines_data = lines
        end,
        place_extmark_highlight = function() end,
      }

      indicator:render(mock_element)

      assert.is_not_nil(set_lines_data)
      assert.is_true(#set_lines_data > 0)
    end)

    it('should center content vertically', function()
      local indicator = LoadingIndicator()
      local set_lines_data = nil
      local mock_element = {
        is_valid = function()
          return true
        end,
        clear_extmark_highlights = function() end,
        get_height = function()
          return 11
        end,
        get_width = function()
          return 40
        end,
        set_lines = function(_, lines)
          set_lines_data = lines
        end,
        place_extmark_highlight = function() end,
      }

      indicator:render(mock_element)

      eq(6, #set_lines_data)
      for i = 1, 5 do
        eq('', set_lines_data[i])
      end

      assert.is_true(#set_lines_data[6] > 0)
    end)

    it('should center content horizontally', function()
      local indicator = LoadingIndicator()
      local set_lines_data = nil
      local mock_element = {
        is_valid = function()
          return true
        end,
        clear_extmark_highlights = function() end,
        get_height = function()
          return 1
        end,
        get_width = function()
          return 40
        end,
        set_lines = function(_, lines)
          set_lines_data = lines
        end,
        place_extmark_highlight = function() end,
      }

      indicator:render(mock_element)

      eq(1, #set_lines_data)

      local line = set_lines_data[1]
      local leading_spaces = line:match('^(%s*)')
      assert.is_true(#leading_spaces > 0)
    end)

    it('should place extmark highlight with GitComment', function()
      local indicator = LoadingIndicator()
      local highlight_data = nil
      local mock_element = {
        is_valid = function()
          return true
        end,
        clear_extmark_highlights = function() end,
        get_height = function()
          return 5
        end,
        get_width = function()
          return 40
        end,
        set_lines = function() end,
        place_extmark_highlight = function(_, opts)
          highlight_data = opts
        end,
      }

      indicator:render(mock_element)

      assert.is_not_nil(highlight_data)
      eq('GitComment', highlight_data.hl)

      eq(2, highlight_data.row)
      assert.is_not_nil(highlight_data.col_range)
      eq(0, highlight_data.col_range.from)
    end)

    it('should clear extmark highlights before rendering', function()
      local indicator = LoadingIndicator()
      local clear_called = false
      local mock_element = {
        is_valid = function()
          return true
        end,
        clear_extmark_highlights = function()
          clear_called = true
        end,
        get_height = function()
          return 5
        end,
        get_width = function()
          return 40
        end,
        set_lines = function() end,
        place_extmark_highlight = function() end,
      }

      indicator:render(mock_element)

      assert.is_true(clear_called)
    end)
  end)
end)
