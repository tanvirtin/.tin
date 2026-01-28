return {
  {
    'ibhagwan/fzf-lua',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    cmd = 'FzfLua',
    opts = {
      keymap = {
        fzf = {
          ['ctrl-q'] = 'select-all+accept',
        },
      },
      winopts = { fullscreen = true },
    },
  },
}
