if vim.async == nil then
  error('tin neovim config requires Neovim nightly (vim.async missing). Validated: v0.13.0-dev-1828+g7e1ae5115f')
end

require('config.options')
require('config.lazy')
require('config.keymaps')
require('config.autocmds')
