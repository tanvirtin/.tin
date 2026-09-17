local eq = assert.are.same

describe('OpenCode draft', function()
  local composer_calls, captured, originals

  before_each(function()
    composer_calls, captured = {}, {}
    originals = {}
    for _, name in ipairs({
      'core.opencode',
      'core.opencode.context',
      'core.opencode.transport',
      'ui.Composer',
    }) do
      originals[name] = package.loaded[name]
      package.loaded[name] = nil
    end

    package.loaded['core.opencode.context'] = {
      capture = function()
        captured[#captured + 1] = { label = 'chip' .. #captured + 1 }
        return captured[#captured]
      end,
      serialize = function(text, chips)
        return text .. '/' .. #chips
      end,
    }
    package.loaded['core.opencode.transport'] = {
      targets = function(callback)
        callback({
          {
            id = 'ses_one',
            session = 'local / main',
            window = 'local/w1',
            title = 'session',
            cwd = '/worktree',
            group = 'local/w1',
            connection = {},
          },
        }, nil, 'local/w1')
      end,
      deliver = function(_, _, callback)
        callback(true, nil)
      end,
    }
    package.loaded['ui.Composer'] = {
      open = function(opts)
        local state = { opts = opts, destroyed = false }
        state.popup = {
          is_destroyed = function()
            return state.destroyed
          end,
          destroy = function()
            state.destroyed = true
          end,
        }
        state.input = {
          focus = function()
            return { start_insert = function() end }
          end,
        }
        composer_calls[#composer_calls + 1] = state
        return state
      end,
    }
  end)

  after_each(function()
    for name, value in pairs(originals) do
      package.loaded[name] = value
    end
  end)

  it('accumulates ranges and the question across composer sessions for the pair', function()
    local oc = require('core.opencode')

    oc.send({ visual = true })
    eq(1, #composer_calls)
    eq(1, #composer_calls[1].opts.chips)

    composer_calls[1].opts.on_draft('my question', composer_calls[1].opts.chips)
    composer_calls[1].destroyed = true

    oc.send({ visual = true })
    eq(2, #composer_calls)
    eq(2, #composer_calls[2].opts.chips)
    eq('my question', composer_calls[2].opts.text)
  end)

  it('drops the chips and text once the draft is cleared', function()
    local oc = require('core.opencode')

    oc.send({ visual = true })
    oc.clear()
    composer_calls[1].destroyed = true

    oc.send({ visual = true })
    eq(1, #composer_calls[2].opts.chips)
    eq('', composer_calls[2].opts.text)
  end)

  it('notifies instead of composing when no session is paired with this instance', function()
    package.loaded['core.opencode.transport'].targets = function(callback)
      callback(nil, 'No OpenCode pane is paired with this Neovim instance. Open one with tin agent open.')
    end
    local oc = require('core.opencode')
    local notified
    local previous = vim.notify
    vim.notify = function(message)
      notified = message
    end

    oc.send({ visual = true })
    vim.notify = previous
    assert.is_truthy(notified and notified:find('tin agent open', 1, true))
    eq(0, #composer_calls)
  end)

  it('refuses to reopen the composer against another group', function()
    local oc = require('core.opencode')
    oc.send({ visual = true })
    eq(1, #composer_calls)
    package.loaded['core.opencode.transport'].targets = function(callback)
      callback({
        {
          id = 'ses_x',
          session = 'x',
          window = 'local/w2',
          title = 'x',
          cwd = '/w/x',
          group = 'local/w2',
          connection = {},
        },
      }, nil, 'local/w2')
    end
    local notified
    local previous = vim.notify
    vim.notify = function(message)
      notified = message
    end
    composer_calls[1].opts.on_target('still the draft', composer_calls[1].opts.chips)
    vim.notify = previous
    assert.is_truthy(notified and notified:find('another group', 1, true))
    eq(1, #composer_calls)
  end)
end)
