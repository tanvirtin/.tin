local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd
local config = require('config')

augroup('YankHighlight', { clear = true })
autocmd('TextYankPost', {
  group = 'YankHighlight',
  callback = function()
    vim.highlight.on_yank()
  end,
})

if config.features.lint_on_save then
  augroup('Linting', { clear = true })
  autocmd({ 'BufWritePost', 'BufReadPost', 'InsertLeave' }, {
    group = 'Linting',
    callback = function()
      require('lint').try_lint()
    end,
  })
end
