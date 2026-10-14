return {
  {
    'tanvirtin/vgit.nvim',
    branch = 'alpha-v2.0.x',
    dependencies = { 'nvim-lua/plenary.nvim', 'nvim-tree/nvim-web-devicons' },
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
          file_diff_view = {
            keymaps = {
              reset = 'r',
              stage = 'S',
              unstage = 'U',
              stage_hunk = 's',
              unstage_hunk = 'u',
              toggle_view = 't',
            },
          },
          status_diff_view = {
            keymaps = {
              reset = 'r',
              stage = 'S',
              unstage = 'U',
              stage_hunk = 's',
              unstage_hunk = 'u',
              toggle_view = 't',
            },
          },
        },
      })
    end,
  },
}
