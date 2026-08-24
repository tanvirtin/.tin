local lazy = require('core.lazy')

local Config = lazy('core.Config')

return Config({
  hunk_alignment = 'top',
  hunk_alignment_offset = 3,
})
