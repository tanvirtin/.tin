local M = {}

local function notify(message, level)
  vim.notify('OpenCode: ' .. message, level or vim.log.levels.INFO)
end

function M.tmux(args)
  local out = vim.fn.system(vim.list_extend({ 'tmux' }, args))
  if vim.v.shell_error ~= 0 then return nil, vim.trim(out) end
  return vim.trim(out)
end

function M.resolve()
  if not vim.env.TMUX_PANE or vim.env.TMUX_PANE == '' then
    return nil, 'Neovim is not running inside a Tin group window.'
  end
  local window, window_err = M.tmux({ 'display-message', '-p', '-t', vim.env.TMUX_PANE, '#{window_id}' })
  if not window then return nil, window_err ~= '' and window_err or 'Could not resolve the tin group window.' end
  local panes, panes_err = M.tmux({ 'list-panes', '-t', window, '-F', '#{pane_id}\t#{@tin_session}\t#{pane_dead}' })
  if not panes then return nil, panes_err ~= '' and panes_err or 'Could not list the group panes.' end
  for line in (panes .. '\n'):gmatch('[^\n]+') do
    local id, session, dead = line:match('^(%S+)\t(%S-)\t(%S+)$')
    if id ~= vim.env.TMUX_PANE and session and session ~= '' and dead == '0' then return id, window end
  end
  return nil, 'No OpenCode chat pane is paired with this Neovim instance. Open one with tin agent open.'
end

function M.toggle()
  local chat, err = M.resolve()
  if not chat then
    notify(err, vim.log.levels.WARN)
    return
  end
  local pane = vim.env.TMUX_PANE
  local state, state_err = M.tmux({ 'display-message', '-p', '-t', pane, '#{window_zoomed_flag}\t#{pane_active}' })
  if not state then
    notify(state_err ~= '' and state_err or 'Could not read the group window state.', vim.log.levels.WARN)
    return
  end
  local zoomed, active = state:match('^(%d)\t(%d)$')
  if zoomed == '1' and active == '1' then
    M.tmux({ 'resize-pane', '-Z', '-t', pane })
  else
    if zoomed == '1' then M.tmux({ 'resize-pane', '-Z', '-t', chat }) end
    M.tmux({ 'resize-pane', '-Z', '-t', pane })
  end
end

return M
