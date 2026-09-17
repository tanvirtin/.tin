local eq = assert.are.same

describe('OpenCode chat', function()
  local Chat, tmux_calls, previous

  local function respond(args)
    if args[1] == 'display-message' and args[5] == '#{window_id}' then return '@12' end
    if args[1] == 'display-message' and args[5] == '#{window_zoomed_flag}\t#{pane_active}' then return '0\t0' end
    if args[1] == 'list-panes' then return '%0\t\t0\n%1\tses_x\t0' end
    return nil, 'unexpected tmux call'
  end

  before_each(function()
    Chat = require('core.opencode.chat')
    tmux_calls = {}
    previous = {
      pane = vim.env.TMUX_PANE,
      notify = vim.notify,
    }
    vim.env.TMUX_PANE = '%0'
    vim.notify = function() end
    Chat.tmux = function(args)
      tmux_calls[#tmux_calls + 1] = args
      return respond(args)
    end
  end)

  after_each(function()
    vim.env.TMUX_PANE = previous.pane
    vim.notify = previous.notify
    package.loaded['core.opencode.chat'] = nil
  end)

  it('zooms Neovim fullscreen and hides the OpenCode pane', function()
    Chat.toggle()
    eq({
      { 'display-message', '-p', '-t', '%0', '#{window_id}' },
      { 'list-panes', '-t', '@12', '-F', '#{pane_id}\t#{@tin_session}\t#{pane_dead}' },
      { 'display-message', '-p', '-t', '%0', '#{window_zoomed_flag}\t#{pane_active}' },
      { 'resize-pane', '-Z', '-t', '%0' },
    }, tmux_calls)
  end)

  it('restores the 73/27 split when Neovim is already zoomed', function()
    local base = respond
    Chat.tmux = function(args)
      tmux_calls[#tmux_calls + 1] = args
      if args[1] == 'display-message' and args[5] == '#{window_zoomed_flag}\t#{pane_active}' then return '1\t1' end
      return base(args)
    end
    Chat.toggle()
    eq({
      { 'display-message', '-p', '-t', '%0', '#{window_id}' },
      { 'list-panes', '-t', '@12', '-F', '#{pane_id}\t#{@tin_session}\t#{pane_dead}' },
      { 'display-message', '-p', '-t', '%0', '#{window_zoomed_flag}\t#{pane_active}' },
      { 'resize-pane', '-Z', '-t', '%0' },
    }, tmux_calls)
  end)

  it('unzooms the chat and zooms Neovim when the chat pane is current', function()
    local base = respond
    Chat.tmux = function(args)
      tmux_calls[#tmux_calls + 1] = args
      if args[1] == 'display-message' and args[5] == '#{window_zoomed_flag}\t#{pane_active}' then return '1\t0' end
      return base(args)
    end
    Chat.toggle()
    eq({
      { 'display-message', '-p', '-t', '%0', '#{window_id}' },
      { 'list-panes', '-t', '@12', '-F', '#{pane_id}\t#{@tin_session}\t#{pane_dead}' },
      { 'display-message', '-p', '-t', '%0', '#{window_zoomed_flag}\t#{pane_active}' },
      { 'resize-pane', '-Z', '-t', '%1' },
      { 'resize-pane', '-Z', '-t', '%0' },
    }, tmux_calls)
  end)

  it('notifies when no OpenCode pane is paired with this window', function()
    Chat.tmux = function(args)
      tmux_calls[#tmux_calls + 1] = args
      if args[1] == 'display-message' then return '@12' end
      if args[1] == 'list-panes' then return '%0\t\t0' end
      return nil
    end
    local notified
    vim.notify = function(message)
      notified = message
    end
    Chat.toggle()
    assert.is_truthy(notified and notified:find('tin agent open', 1, true))
    eq(2, #tmux_calls)
  end)

  it('notifies when Neovim is not running inside tmux', function()
    vim.env.TMUX_PANE = ''
    local notified
    vim.notify = function(message)
      notified = message
    end
    Chat.toggle()
    assert.is_truthy(notified and notified:find('Tin group window', 1, true))
    eq(0, #tmux_calls)
  end)
end)
