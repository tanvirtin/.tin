local M = {}

function M.capture(visual)
  local buffer = vim.api.nvim_get_current_buf()
  local first, last = vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[1]
  if visual then
    first, last = vim.fn.line('\'<'), vim.fn.line('\'>')
    if first > last then
      first, last = last, first
    end
  end
  if first < 1 or last > vim.api.nvim_buf_line_count(buffer) then
    return nil, 'Select a range in a source buffer first.'
  end
  local path = vim.api.nvim_buf_get_name(buffer)
  local label = path == '' and '[Untitled]' or vim.fn.fnamemodify(path, ':t')
  local lines = vim.api.nvim_buf_get_lines(buffer, first - 1, last, false)
  if vim.trim(table.concat(lines, '\n')) == '' then return nil, 'Nothing to send: that range is empty.' end
  local preview = { string.format('%s · %d lines · buffer snapshot', label, #lines) }
  for i = 1, math.min(5, #lines) do
    preview[#preview + 1] = string.format('%d  %s', first + i - 1, lines[i])
  end
  return {
    label = string.format('%s:%d–%d', label, first, last),
    path = path == '' and '[Untitled buffer]' or path,
    first = first,
    last = last,
    filetype = vim.bo[buffer].filetype,
    text = table.concat(lines, '\n'),
    preview = preview,
  }
end

function M.serialize(question, chips)
  local parts = { vim.trim(question) }
  for _, chip in ipairs(chips) do
    local length = 3
    for fence in chip.text:gmatch('`+') do
      length = math.max(length, #fence + 1)
    end
    local fence = string.rep('`', length)
    parts[#parts + 1] = string.format(
      'File: %s (lines %d–%d; editor snapshot)\n%s%s\n%s\n%s',
      chip.path,
      chip.first,
      chip.last,
      fence,
      chip.filetype,
      chip.text,
      fence
    )
  end
  return table.concat(parts, '\n\n')
end

return M
