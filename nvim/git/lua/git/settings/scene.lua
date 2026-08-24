local lazy = require('core.lazy')

local Config = lazy('core.Config')

return Config({
  diff_preference = 'unified',
  keymaps = { quit = '<esc>' },
})
