local Fold = {}

function Fold.setup_window(win_id)
  local options = {
    foldmethod = 'manual',
    foldlevel = 0,
    foldenable = true,
    foldtext = 'v:lua.require("core.Fold").foldtext()',
  }

  for key, value in pairs(options) do
    pcall(vim.api.nvim_set_option_value, key, value, { win = win_id })
  end

  return Fold
end

function Fold.close_range(win_id, start_line, end_line)
  vim.api.nvim_win_call(win_id, function()
    Fold.close_range_current(start_line, end_line)
  end)
  return Fold
end

function Fold.open_all(win_id)
  vim.api.nvim_win_call(win_id, function()
    Fold.open_all_current()
  end)
  return Fold
end

function Fold.close_range_current(start_line, end_line)
  vim.cmd(string.format('silent! noautocmd %s,%sfold', start_line, end_line))
end

function Fold.open_all_current()
  vim.cmd('silent! noautocmd normal! zR')
end

function Fold.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return string.format('  %d lines folded - zo open | zc close', count)
end

return Fold
