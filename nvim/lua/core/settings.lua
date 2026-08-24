local registered = {}
local default_resolver = function(name)
  return require('git.settings.' .. name)
end

local settings = {}

-- Allows plugins to override where unregistered settings are resolved from.
-- The default resolver maps `name` to the `tings.settings.<name>` module.
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

-- Returns the config instance for `name`.
--
-- Explicitly registered configs (registered during setup) are returned
-- directly. Unregistered names resolve lazily through the default resolver
-- on first member access, deferring `require` until the settings module is
-- actually used (matching how consumers previously relied on lazy proxies).
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
