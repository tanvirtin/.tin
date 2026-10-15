if vim.async == nil then error('tin neovim is outdated') end

require('config.options')
require('config.lazy')
require('config.keymaps')
require('config.autocmds')
require('config.diagnostics')
