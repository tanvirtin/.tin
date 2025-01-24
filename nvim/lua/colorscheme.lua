local colorscheme = {}

function colorscheme.init()
  pcall(vim.cmd, 'colorscheme tokyonight')
end

return colorscheme
