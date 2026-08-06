-- Standard utility functions used throughout the app.

local lazy = require('core.lazy')

local utils = {
  str = lazy('core.utils.str'),
  list = lazy('core.utils.list'),
  date = lazy('core.utils.date'),
  math = lazy('core.utils.math'),
  value = lazy('core.utils.value'),
  object = lazy('core.utils.object'),
}

return utils
