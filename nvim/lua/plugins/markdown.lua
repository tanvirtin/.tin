return {
  'MeanderingProgrammer/render-markdown.nvim',
  ft = { 'markdown', 'tin_chat' },
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  opts = {
    file_types = { 'markdown', 'tin_chat' },
    overrides = {
      filetype = {
        tin_chat = {
          render_modes = true,
        },
      },
    },
  },
}
