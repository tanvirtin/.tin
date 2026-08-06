local lazy = require('core.lazy')

local console = lazy('core.console')

local router = {}

local COMMAND_MAP = {
  diff = 'tingit.cli.commands.diff',
  blame = 'tingit.cli.commands.blame',
  hunk = 'tingit.cli.commands.hunk',
  status = 'tingit.cli.commands.status',
  show = 'tingit.cli.commands.show',
  branch = 'tingit.cli.commands.branch',
  log = 'tingit.cli.commands.log',
  debug = 'tingit.cli.commands.debug',
  stash = 'tingit.cli.commands.stash',
  worktree = 'tingit.cli.commands.worktree',
  commit = 'tingit.cli.commands.commit',
}

function router.execute(args)
  if not args or #args == 0 then
    console.error('No command provided')
    return
  end

  local command = args[1]
  local command_args = {}
  for i = 2, #args do
    table.insert(command_args, args[i])
  end

  local handler_module = COMMAND_MAP[command]
  if not handler_module then
    console.error('Unknown command: ' .. command)
    return
  end

  local ok, handler = pcall(require, handler_module)
  if not ok then
    console.error('Failed to load command: ' .. command .. ': ' .. tostring(handler))
    return
  end
  if type(handler.execute) ~= 'function' then
    console.error('Failed to load command: ' .. command)
    return
  end

  handler.execute(command_args)
end

return router
