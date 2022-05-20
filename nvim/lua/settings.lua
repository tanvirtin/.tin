local settings = {
  opts = {
    list = true,
    mouse = 'a',
    backup = false,
    tabstop = 2,
    showmode = false,
    hlsearch = true,
    pumheight = 10,
    listchars = 'eol:↲,tab:--,extends:…,precedes:…,conceal:┊,nbsp:☠',
    clipboard = 'unnamedplus',
    cmdheight = 1,
    shiftwidth = 2,
    completeopt = { 'menuone', 'noselect' },
    conceallevel = 0,
    fileencoding = 'utf-8',
    ignorecase = true,
    smartcase = true,
    smartindent = true,
    splitbelow = true,
    splitright = true,
    swapfile = false,
    timeoutlen = 1000,
    undofile = true,
    updatetime = 300,
    writebackup = false,
    expandtab = true,
    cursorline = true,
    number = true,
    relativenumber = false,
    numberwidth = 4,
    signcolumn = 'yes',
    wrap = false,
    incsearch = false,
  },
}

function settings.register_defaults()
  vim.opt.shortmess:append('c')
  vim.cmd('set whichwrap+=<,>,[,],h,l')
  vim.cmd([[set iskeyword+=-]])
  vim.cmd('set termguicolors')
  vim.cmd('autocmd TextYankPost * lua vim.highlight.on_yank()')
end

function settings.set_default_opts()
  for k, v in pairs(settings.opts) do
    vim.opt[k] = v
  end

  vim.o.ch = 0
  vim.o.ls = 0
end

function settings.init()
  settings.register_defaults()
  settings.set_default_opts()
end

return settings
