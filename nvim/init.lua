local lsp = require('lsp')
local keymaps = require('keymaps')
local settings = require('settings')
local colorscheme = require('colorscheme')
local package_manager = require('package_manager')

colorscheme.init()
package_manager.init()
keymaps.init()
settings.init()
lsp.init()
