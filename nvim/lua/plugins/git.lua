return {
  {
    dir = '~/workspace/vgit.nvim',
    dependencies = { 'nvim-lua/plenary.nvim' },
    event = 'VimEnter',
    config = function()
      require('vgit').setup({
        keymaps = {
          ['n <C-k>'] = 'hunk_up',
          {
            mode = 'n',
            key = '<C-j>',
            handler = 'hunk_down',
          },
        },
        settings = {
          libgit2 = {
            enabled = true,
            path = '/opt/homebrew/opt/libgit2/lib/libgit2.dylib',
          },
          live_blame = {
            enabled = true,
          },
          live_gutter = {
            enabled = true,
          },
          scene = {
            diff_preference = 'unified',
            keymaps = { quit = '<C-c>' },
          },
          diff_view = {
            keymaps = {
              reset = 'r',
              buffer_stage = 'S',
              buffer_unstage = 'U',
              buffer_hunk_stage = 's',
              buffer_hunk_unstage = 'u',
              toggle_view = 't',
            },
          },
        },
      })
    end,
  },
}
