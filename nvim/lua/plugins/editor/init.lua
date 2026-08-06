local neo_tree = require('plugins.editor.neo-tree')
local fzf = require('plugins.editor.fzf')

return vim.list_extend({
  {
    'folke/which-key.nvim',
    event = 'VeryLazy',
    opts = {},
  },
  {
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    opts = {},
  },
  {
    'nmac427/guess-indent.nvim',
    event = { 'BufReadPre', 'BufNewFile' },
    opts = {},
  },
}, vim.list_extend(neo_tree, fzf))
