local Client = require('core.opencode.client')

local M = {}

function M.targets(callback)
  local discovery = Client.new({})
  discovery:call('group', {}, nil, function(group, err)
    discovery:close()
    if err then return callback(nil, err) end
    if not group.session then
      return callback(nil, 'No OpenCode pane is paired with this Neovim instance. Open one with tin agent open.')
    end
    callback(
      {
        {
          id = group.session,
          session = group.label or group.name,
          window = group.group,
          title = group.label or group.name,
          cwd = group.directory,
          group = group.group,
          connection = group,
        },
      },
      nil,
      group.group
    )
  end)
end

function M.deliver(target, text, callback)
  local client = Client.new(target.connection)
  client:call('prompt', { target.id }, text, function(ok, err)
    client:close()
    callback(ok and not err or false, err)
  end)
end

return M
