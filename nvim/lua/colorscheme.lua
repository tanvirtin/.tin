local colorscheme = {}

function colorscheme.init()
  vim.cmd('syntax on')
  pcall(vim.cmd, 'colorscheme monokai')

  return colorscheme
end

return colorscheme
