local lazy = require('core.lazy')

local Config = lazy('core.Config')

return Config({
  enabled = true,
  debounce_ms = 200,
  edge_navigation = true,
})
