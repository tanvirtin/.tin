local Fold = require('core.Fold')

describe('Fold:', function()
  local bufnr
  local win_id

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'one', 'two', 'three', 'four', 'five' })
    vim.cmd('split')
    win_id = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win_id, bufnr)
    Fold.setup_window(win_id)
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win_id, true)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  describe('setup_window', function()
    it('sets manual folding options', function()
      assert.are.equal('manual', vim.api.nvim_get_option_value('foldmethod', { win = win_id }))
      assert.are.equal(0, vim.api.nvim_get_option_value('foldlevel', { win = win_id }))
      assert.is_true(vim.api.nvim_get_option_value('foldenable', { win = win_id }))
    end)
  end)

  describe('close_range', function()
    it('creates a fold over the range', function()
      Fold.close_range(win_id, 2, 4)

      assert.are.equal(2, vim.fn.foldclosed(2))
      assert.are.equal(2, vim.fn.foldclosed(3))
      assert.are.equal(2, vim.fn.foldclosed(4))
      assert.are.equal(-1, vim.fn.foldclosed(1))
    end)
  end)

  describe('open_all', function()
    it('clears all folds', function()
      Fold.close_range(win_id, 2, 4)
      Fold.open_all(win_id)

      assert.are.equal(-1, vim.fn.foldclosed(2))
    end)
  end)

  describe('foldtext', function()
    it('reports the folded line count', function()
      vim.api.nvim_set_vvar('foldstart', 2)
      vim.api.nvim_set_vvar('foldend', 4)

      assert.are.equal('  3 lines folded - zo open | zc close', Fold.foldtext())
    end)
  end)
end)
