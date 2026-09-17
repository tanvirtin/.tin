local neo_tree = require('plugins.editor.neo-tree')
local fzf = require('plugins.editor.fzf')

return vim.list_extend(vim.list_extend({
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
}, neo_tree), fzf)
