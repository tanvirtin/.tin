local eq = assert.are.same
local assertions = require('ui.assertions')

describe('assertions:', function()
  describe('get_buffer_lines', function()
    it('returns all buffer lines', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a', 'b' })

      eq({ 'a', 'b' }, assertions.get_buffer_lines(bufnr))

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('get_extmarks', function()
    it('returns extmarks with details for a namespace', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'hello' })
      vim.api.nvim_buf_set_extmark(
        bufnr,
        vim.api.nvim_create_namespace('test.ns'),
        0,
        0,
        { virt_text = { { 'x', 'Comment' } } }
      )

      local marks = assertions.get_extmarks(bufnr, 'test.ns')
      eq(1, #marks)
      eq('x', marks[1][4].virt_text[1][1])

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('get_folds', function()
    it('lists closed fold ranges', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a', 'b', 'c', 'd' })
      vim.cmd('split')
      local win_id = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win_id, bufnr)
      vim.api.nvim_set_option_value('foldmethod', 'manual', { win = win_id })
      vim.cmd('2,3fold')

      local folds = assertions.get_folds(bufnr)
      eq(1, #folds)
      eq(2, folds[1].top)
      eq(3, folds[1].bot)

      pcall(vim.api.nvim_win_close, win_id, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('count_windows_for_buf', function()
    it('counts windows showing a buffer', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.cmd('split')
      local win_id = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win_id, bufnr)

      eq(1, assertions.count_windows_for_buf(bufnr))

      pcall(vim.api.nvim_win_close, win_id, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
