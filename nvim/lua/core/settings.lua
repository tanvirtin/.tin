local registered = {}
local default_resolver = function(name)
  return require('git.settings.' .. name)
end

local settings = {}

function settings.set_default_resolver(resolver)
  default_resolver = resolver

  return settings
end

function settings.register(name, config)
  registered[name] = config

  return settings
end

function settings.is_registered(name)
  return registered[name] ~= nil
end

function settings.get(name)
  if registered[name] ~= nil then return registered[name] end

  local module

  return setmetatable({}, {
    __index = function(_, key)
      if not module then module = default_resolver(name) end
      return module[key]
    end,
    __call = function(_, ...)
      if not module then module = default_resolver(name) end
      return module(...)
    end,
  })
end

function settings.for_each(callback)
  for name, config in pairs(registered) do
    callback(name, config)
  end

  return settings
end

return settings
