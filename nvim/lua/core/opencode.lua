local Context = require('core.opencode.context')
local Transport = require('core.opencode.transport')

local M = {}
local active
local discovering = false
local draft = { target = nil, text = '', chips = {} }

M.targets = Transport.targets

local function notify(message, level)
  vim.notify('OpenCode: ' .. message, level or vim.log.levels.INFO)
end

local compose, choose

compose = function(target)
  draft.target = target
  active = require('ui.Composer').open({
    title = 'OpenCode · Ask about code',
    target = string.format('%s  /  %s  %s', target.session, target.window, target.title),
    text = draft.text,
    chips = draft.chips,
    allow_paste = false,
    on_draft = function(text, chips)
      draft.text, draft.chips = text, chips
    end,
    on_target = function(text, chips)
      draft.text, draft.chips = text, chips
      choose(target)
    end,
    on_submit = function(text, chips, _, done)
      draft.text, draft.chips = text, chips
      Transport.deliver(target, Context.serialize(text, chips), function(ok, send_err)
        done(ok, send_err)
        if ok then
          draft.text, draft.chips = '', {}
          notify('Sent to ' .. target.session .. ' / ' .. target.title)
        end
      end)
    end,
  })
end

choose = function(previous, chip)
  discovering = true
  Transport.targets(function(panes, discovery_err, group)
    discovering = false
    local pane = panes and panes[1]
    if not pane then
      notify(
        discovery_err or 'No OpenCode session is paired with this Neovim instance. Open one with tin agent open.',
        vim.log.levels.WARN
      )
      return
    end
    if previous and previous.group ~= group then
      return notify('The editor moved to another group. Reopen the composer there.', vim.log.levels.WARN)
    end
    if chip then
      draft.chips[#draft.chips + 1] = chip
      if #draft.chips > 1 then notify(string.format('Context added (%d chips)', #draft.chips)) end
    end
    compose(pane)
  end)
end

function M.send(opts)
  if discovering then return end
  if active and not active.popup:is_destroyed() then
    active.input:focus():start_insert()
    return
  end
  opts = opts or {}
  local chip, err = Context.capture(opts.visual)
  if not chip then return notify(err, vim.log.levels.WARN) end
  choose(nil, chip)
end

function M.clear()
  draft.text, draft.chips = '', {}
  if active and not active.popup:is_destroyed() then
    active.completed = true
    active.popup:destroy()
  end
  notify('Draft cleared.')
end

function M.teardown()
  local pane = vim.env.TMUX_PANE
  if not pane or pane == '' then return end
  local window = vim.trim(vim.fn.system({ 'tmux', 'display-message', '-p', '-t', pane, '#{window_id}' }))
  if vim.v.shell_error ~= 0 or window == '' then return end
  local panes = vim.fn.system({ 'tmux', 'list-panes', '-t', window, '-F', '#{pane_id}' })
  if vim.v.shell_error ~= 0 then return end
  for id in (panes or ''):gmatch('[^\n]+') do
    if id ~= pane then vim.fn.system({ 'tmux', 'kill-pane', '-t', id }) end
  end
end

return M
