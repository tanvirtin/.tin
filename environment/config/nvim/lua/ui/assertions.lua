local M = {}

function M.get_buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.get_extmarks(bufnr, ns_name)
  local namespaces = vim.api.nvim_get_namespaces()
  local ns_id = namespaces[ns_name] or vim.api.nvim_create_namespace(ns_name)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
end

function M.get_folds(bufnr)
  local folds = {}
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local i = 1

  while i <= line_count do
    local closed = vim.fn.foldclosed(i)
    if closed ~= -1 then
      folds[#folds + 1] = { top = closed, bot = vim.fn.foldclosedend(i) }
      i = vim.fn.foldclosedend(i) + 1
    else
      i = i + 1
    end
  end

  return folds
end

function M.get_win_option(win_id, key)
  return vim.api.nvim_get_option_value(key, { win = win_id })
end

function M.count_windows_for_buf(bufnr)
  local count = 0
  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win_id) and vim.api.nvim_win_get_buf(win_id) == bufnr then count = count + 1 end
  end
  return count
end

return M
