local colorscheme = {}

function colorscheme.init()
	pcall(vim.cmd, "colorscheme monokai")
end

return colorscheme
