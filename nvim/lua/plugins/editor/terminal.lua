local opencode_terminal

local function get_opencode_terminal()
  local Terminal = require('toggleterm.terminal').Terminal

  opencode_terminal = opencode_terminal
    or Terminal:new({
      cmd = 'opencode --continue',
      count = 1,
      direction = 'float',
      float_opts = {
        border = 'rounded',
        width = function()
          return math.floor(vim.o.columns * 0.8)
        end,
        height = function()
          return math.floor(vim.o.lines * 0.85)
        end,
      },
      close_on_exit = true,
      on_open = function()
        vim.cmd('startinsert!')
      end,
    })

  return opencode_terminal
end

return {
  {
    'akinsho/toggleterm.nvim',
    version = '*',
    keys = {
      {
        '<leader><tab>',
        function()
          get_opencode_terminal():toggle()
        end,
        desc = 'Toggle opencode',
        mode = { 'n', 't' },
      },
    },
    opts = {},
  },
}
