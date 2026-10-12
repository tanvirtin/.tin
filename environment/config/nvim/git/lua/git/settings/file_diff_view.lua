local lazy = require('core.lazy')

local Config = lazy('core.Config')

return Config({
  hunk_alignment = 'center',
  hunk_alignment_offset = 0,
  keymaps = {
    stage = { key = 's', desc = 'Stage file' },
    unstage = { key = 'u', desc = 'Unstage file' },
    reset = { key = 'r', desc = 'Reset file' },
    stage_hunk = { key = '<leader>s', desc = 'Stage hunk' },
    unstage_hunk = { key = '<leader>u', desc = 'Unstage hunk' },
    toggle_view = { key = 't', desc = 'Toggle staged/unstaged' },
  },
})
