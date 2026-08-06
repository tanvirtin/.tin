local lazy = require('core.lazy')

local Config = lazy('core.Config')

return Config({
  cmd = 'git',
  algorithm = 'myers',
  fallback_cwd = '',
  fallback_args = {},
})
