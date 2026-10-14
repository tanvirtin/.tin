local registered = {}

local function empty_settings()
  local empty = {}

  function empty:get()
    return nil
  end
  function empty:for_each()
    return empty
  end
  function empty:set()
    return empty
  end
  function empty:assign()
    return empty
  end

  return empty
end

local function neutral_resolver()
  return empty_settings()
end

local default_resolver = neutral_resolver

local settings = {}

function settings.set_default_resolver(resolver)
  default_resolver = resolver

  return settings
end

function settings.reset_default_resolver()
  default_resolver = neutral_resolver

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
