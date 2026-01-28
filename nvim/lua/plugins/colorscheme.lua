local config = require('config')

return {
  {
    'tanvirtin/monokai.nvim',
    lazy = false,
    priority = 1000,
    config = function()
      if config.colorscheme == 'monokai' then
        vim.cmd.colorscheme('monokai')
      end
    end,
  },
  {
    'folke/tokyonight.nvim',
    lazy = false,
    priority = 1000,
    opts = {
      style = 'night',
    },
    config = function(_, opts)
      require('tokyonight').setup(opts)
      if config.colorscheme == 'tokyonight' then
        vim.cmd.colorscheme('tokyonight')
      end
    end,
  },
}
