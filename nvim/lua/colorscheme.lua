local colorscheme = {}

function colorscheme.init()
	vim.cmd("syntax on")
	pcall(vim.cmd, "colorscheme tokyonight")
end

return colorscheme
