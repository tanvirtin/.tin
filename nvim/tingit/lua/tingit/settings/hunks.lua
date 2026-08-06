local lazy = require('core.lazy')

local Config = lazy('core.Config')

return Config({
  hunk_alignment = 'center',
  hunk_alignment_offset = 0,
  keymaps = {
    down = { key = '<C-j>', desc = 'Next hunk' },
    up = { key = '<C-k>', desc = 'Previous hunk' },
  },
})
