local lazy = require('core.lazy')

local fs = lazy('core.fs')

return function(filepath, repo_path)
  if not filepath or filepath == '' then return filepath end
  local absolute = vim.fn.fnamemodify(filepath, ':p')
  return fs.make_relative(repo_path, absolute)
end
