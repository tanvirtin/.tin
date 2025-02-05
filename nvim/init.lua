local keymaps = require('keymaps')
local settings = require('settings')
local colorscheme = require('colorscheme')
local package_manager = require('package_manager')

package_manager.init()
colorscheme.init()
keymaps.init()
settings.init()
