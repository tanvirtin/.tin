local lazy = require('core.lazy')

local console = lazy('core.console')

local router = {}

local COMMAND_MAP = {
  diff = 'git.cli.commands.diff',
  blame = 'git.cli.commands.blame',
  hunk = 'git.cli.commands.hunk',
  status = 'git.cli.commands.status',
  show = 'git.cli.commands.show',
  branch = 'git.cli.commands.branch',
  log = 'git.cli.commands.log',
  debug = 'git.cli.commands.debug',
  stash = 'git.cli.commands.stash',
  worktree = 'git.cli.commands.worktree',
  commit = 'git.cli.commands.commit',
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

function router.commands()
  return vim.tbl_keys(COMMAND_MAP)
end

return router
