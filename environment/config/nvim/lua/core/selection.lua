local M = {}

local _selections = {}

function M.new(file, start_line, end_line, start_col, end_col)
  local lines_reversed = start_line > end_line

  if lines_reversed then
    start_line, end_line = end_line, start_line
    if start_col and end_col then
      start_col, end_col = end_col, start_col
    end
  end

  local same_line = start_line == end_line
  if same_line and start_col and end_col and start_col > end_col then
    start_col, end_col = end_col, start_col
  end

  return {
    file = file,
    start_line = start_line,
    end_line = end_line,
    start_col = start_col,
    end_col = end_col,
  }
end

function M.relative_path(absolute_path, root)
  if root:sub(-1) ~= '/' then root = root .. '/' end

  if absolute_path:sub(1, #root) ~= root then return absolute_path end

  return absolute_path:sub(#root + 1)
end

function M.format(selection)
  local has_cols = selection.start_col ~= nil

  if not has_cols then
    if selection.start_line == selection.end_line then return selection.file .. ':' .. selection.start_line end
    return selection.file .. ':' .. selection.start_line .. '-' .. selection.end_line
  end

  local start_pos = selection.start_line .. ':' .. selection.start_col
  local end_pos = selection.end_line .. ':' .. selection.end_col
  local is_single_pos = start_pos == end_pos

  if is_single_pos then return selection.file .. ':' .. start_pos end

  return selection.file .. ':' .. start_pos .. '-' .. end_pos
end

function M.format_many(selections)
  if #selections == 0 then return '' end

  local file_order = {}
  local ranges_by_file = {}

  for _, s in ipairs(selections) do
    if not ranges_by_file[s.file] then
      file_order[#file_order + 1] = s.file
      ranges_by_file[s.file] = {}
    end
    local ranges = ranges_by_file[s.file]
    local formatted = M.format(s)
    local range_part = formatted:sub(#s.file + 2)
    ranges[#ranges + 1] = range_part
  end

  local lines = {}
  for _, file in ipairs(file_order) do
    lines[#lines + 1] = file .. ':' .. table.concat(ranges_by_file[file], ',')
  end

  return table.concat(lines, ' ')
end

function M.capture()
  local start_mark = vim.fn.getpos('\'<')
  local end_mark = vim.fn.getpos('\'>')
  local mode = vim.fn.visualmode()

  local start_line = start_mark[2]
  local end_line = end_mark[2]
  local start_col = nil
  local end_col = nil

  local is_line_wise = mode == 'V'
  if not is_line_wise then
    start_col = start_mark[3]
    end_col = end_mark[3]
  end

  local absolute_path = vim.api.nvim_buf_get_name(0)
  local cwd = vim.fn.getcwd()
  local file = M.relative_path(absolute_path, cwd)

  return M.new(file, start_line, end_line, start_col, end_col)
end

function M.yank()
  local s = M.capture()
  local text = M.format(s)
  vim.fn.setreg('+', text)
  vim.notify(text, vim.log.levels.INFO)
end

function M.add()
  local s = M.capture()
  _selections[#_selections + 1] = s
  local count = #_selections
  vim.notify('selection ' .. count .. ': ' .. M.format(s), vim.log.levels.INFO)
end

function M.flush()
  if #_selections == 0 then
    vim.notify('no selections to flush', vim.log.levels.WARN)
    return
  end

  local text = M.format_many(_selections)
  vim.fn.setreg('+', text)
  local count = #_selections
  M.clear()
  vim.notify(count .. ' selection(s) copied', vim.log.levels.INFO)
end

function M.clear()
  _selections = {}
end

function M.peek()
  local copy = {}
  for i, s in ipairs(_selections) do
    copy[i] = s
  end
  return copy
end

return M
