local Context = require('core.opencode.context')
local eq = assert.are.same

describe('OpenCode context', function()
  it('captures unsaved ranges before the editor focus changes and fences embedded markdown', function()
    vim.cmd('enew!')
    vim.api.nvim_buf_set_name(0, '/tmp/tin-context.lua')
    vim.bo.filetype = 'lua'
    vim.api.nvim_buf_set_lines(
      0,
      0,
      -1,
      false,
      { 'not selected', 'local unsaved = "```"', 'return unsaved', 'not selected' }
    )
    vim.api.nvim_buf_set_mark(0, '<', 2, 0, {})
    vim.api.nvim_buf_set_mark(0, '>', 3, 0, {})
    local chip = Context.capture(true)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited later' })
    vim.cmd('enew!')
    local text = Context.serialize('Explain this flow', { chip })
    assert.is_truthy(text:find('Explain this flow', 1, true))
    assert.is_truthy(text:find('/tmp/tin-context.lua', 1, true))
    assert.is_truthy(text:find('````lua\nlocal unsaved = "```"\nreturn unsaved\n````', 1, true))
    assert.is_nil(text:find('not selected', 1, true))
    assert.is_nil(text:find('edited later', 1, true))
  end)

  it('refuses empty and whitespace-only ranges', function()
    vim.cmd('enew!')
    local chip, err = Context.capture(false)
    assert.is_nil(chip)
    assert.is_truthy(err:find('empty', 1, true))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '   ', '\t' })
    chip, err = Context.capture(false)
    assert.is_nil(chip)
    assert.is_truthy(err:find('empty', 1, true))
  end)
end)

describe('OpenCode group transport', function()
  local Client, calls, original

  before_each(function()
    Client = require('core.opencode.client')
    original = Client.new
    calls = {}
    Client.new = function(opts)
      return {
        opts = opts,
        call = function(_, action, args, input, callback)
          calls[#calls + 1] = { action = action, args = args, input = input, callback = callback }
        end,
        close = function() end,
      }
    end
  end)

  after_each(function()
    Client.new = original
  end)

  it('targets exactly the session paired with this group', function()
    local Transport = require('core.opencode.transport')
    local done, targets, group
    Transport.targets(function(value, _, label)
      targets, group, done = value, label, true
    end)
    eq('group', calls[1].action)
    calls[1].callback({
      name = 'local',
      directory = '/worktree',
      group = 'local/w1',
      label = 'local / main',
      coordinator = 'ses_root',
      session = 'ses_root',
      pane = '%59',
    })
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    eq(1, #targets)
    eq('ses_root', targets[1].id)
    eq('local/w1', targets[1].group)
    eq('local / main', targets[1].session)
    eq('local/w1', group)
  end)

  it('reports a missing pair instead of enumerating sessions', function()
    local Transport = require('core.opencode.transport')
    local done, targets, err
    Transport.targets(function(value, message)
      targets, err, done = value, message, true
    end)
    calls[1].callback({
      name = 'local',
      directory = '/worktree',
      group = 'local/w1',
      label = 'local / main',
      coordinator = 'ses_root',
    })
    assert.is_true(vim.wait(1000, function()
      return done
    end))
    eq(1, #calls)
    assert.is_nil(targets)
    assert.is_truthy(err:find('tin agent open', 1, true))
  end)
end)
