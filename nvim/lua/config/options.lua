local opt = vim.opt

vim.g.mapleader = ','
vim.g.maplocalleader = ','

opt.mouse = 'a'
opt.backup = false
opt.tabstop = 2
opt.showmode = false
opt.hlsearch = true
opt.pumheight = 10
opt.listchars = 'eol:↲,tab:--,extends:…,precedes:…,conceal:┊,nbsp:☠'
opt.clipboard = 'unnamedplus'
opt.cmdheight = 1
opt.shiftwidth = 2
opt.completeopt = { 'menuone', 'noselect' }
opt.conceallevel = 0
opt.fileencoding = 'utf-8'
opt.ignorecase = true
opt.smartcase = true
opt.smartindent = true
opt.splitbelow = true
opt.splitright = true
opt.swapfile = false
opt.timeoutlen = 1000
opt.undofile = true
opt.updatetime = 300
opt.writebackup = false
opt.expandtab = true
opt.cursorline = true
opt.number = true
opt.relativenumber = false
opt.numberwidth = 4
opt.signcolumn = 'yes'
opt.hidden = true
opt.wrap = false
opt.incsearch = false
opt.termguicolors = true

opt.shortmess:append('c')

vim.o.ch = 0
vim.o.ls = 0

vim.cmd('set whichwrap+=<,>,[,],h,l')
vim.cmd([[set iskeyword+=-]])
