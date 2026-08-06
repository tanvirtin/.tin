local mock = require('luassert.mock')
local keymap = require('core.keymap')

local eq = assert.are.same

describe('keymap:', function()
  before_each(function()
    vim.api = mock(vim.api, true)
  end)

  after_each(function()
    mock.revert(vim.api)
  end)

  describe('define', function()
    it('should call vim api internally to define the given keys', function()
      local expected = {
        { 'n', '<C-k>', '<Cmd>lua require("tingit").hunk_up()<CR>', 'Tingit:hunk_up' },
        { 'n', '<C-j>', '<Cmd>lua require("tingit").hunk_down()<CR>', 'Tingit:hunk_down' },
        {
          'n',
          '<leader>gs',
          '<Cmd>lua require("tingit").buffer_hunk_stage()<CR>',
          'Tingit:buffer_hunk_stage',
        },
        {
          'n',
          '<leader>gr',
          '<Cmd>lua require("tingit").buffer_hunk_reset()<CR>',
          'Tingit:buffer_hunk_reset',
        },
        {
          'n',
          '<leader>gp',
          '<Cmd>lua require("tingit").buffer_hunk_preview()<CR>',
          'Tingit:buffer_hunk_preview',
        },
        {
          'n',
          '<leader>gb',
          '<Cmd>lua require("tingit").buffer_blame_preview()<CR>',
          'Tingit:buffer_blame_preview',
        },
        {
          'n',
          '<leader>gf',
          '<Cmd>lua require("tingit").buffer_diff_preview()<CR>',
          'Tingit:buffer_diff_preview',
        },
        {
          'n',
          '<leader>gh',
          '<Cmd>lua require("tingit").buffer_history_preview()<CR>',
          'Tingit:buffer_history_preview',
        },
        { 'n', '<leader>gu', '<Cmd>lua require("tingit").buffer_reset()<CR>', 'Tingit:buffer_reset' },
        {
          'n',
          '<leader>gg',
          '<Cmd>lua require("tingit").buffer_gutter_blame_preview()<CR>',
          'Tingit:buffer_gutter_blame_preview',
        },
        {
          'n',
          '<leader>gd',
          '<Cmd>lua require("tingit").project_diff_preview()<CR>',
          'Tingit:project_diff_preview',
        },
        {
          'n',
          '<leader>gx',
          '<Cmd>lua require("tingit").toggle_diff_preference()<CR>',
          'Tingit:toggle_diff_preference',
        },
      }

      keymap.define({
        ['n <C-k>'] = 'hunk_up',
        ['n <C-j>'] = 'hunk_down',
        ['n <leader>gs'] = 'buffer_hunk_stage',
        ['n <leader>gr'] = 'buffer_hunk_reset',
        ['n <leader>gp'] = 'buffer_hunk_preview',
        ['n <leader>gb'] = 'buffer_blame_preview',
        ['n <leader>gf'] = 'buffer_diff_preview',
        ['n <leader>gh'] = 'buffer_history_preview',
        ['n <leader>gu'] = 'buffer_reset',
        ['n <leader>gg'] = 'buffer_gutter_blame_preview',
        ['n <leader>gd'] = 'project_diff_preview',
        ['n <leader>gx'] = 'toggle_diff_preference',
      })

      for index in ipairs(expected) do
        assert
          .stub(vim.api.nvim_set_keymap).was
          .called_with(expected[index][1], expected[index][2], expected[index][3], {
            noremap = true,
            silent = true,
            desc = expected[index][4],
          })
      end
    end)
  end)
end)
