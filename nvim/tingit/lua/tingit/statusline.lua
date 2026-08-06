local lazy = require('core.lazy')

local statusline_state = lazy('tingit.core.statusline_state')

local statusline = {}

statusline.get_hunk = function(...)
  return statusline_state.get_hunk(...)
end
statusline.get_diff_stats = function(...)
  return statusline_state.get_diff_stats(...)
end
statusline.get_branch = function(...)
  return statusline_state.get_branch(...)
end

return statusline
