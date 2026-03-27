return {
  { 'nvim-tree/nvim-web-devicons', lazy = true },
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    event = 'VimEnter',
    opts = {
      options = {
        theme = 'auto',
        component_separators = { left = '', right = '' },
        section_separators = { left = '', right = '' },
        disabled_filetypes = { statusline = { 'neo-tree' } },
        globalstatus = true,
      },
      sections = {
        lualine_a = {
          { 'mode', icon = '' },
        },
        lualine_b = {
          { 'branch', icon = '' },
          {
            function()
              local ok, sl = pcall(require, 'vgit.statusline')
              if not ok then return '' end
              local h = sl.get_hunk()
              if h then return string.format('Hunk %d/%d', h.index, h.count) end
              return ''
            end,
            cond = function()
              local ok, sl = pcall(require, 'vgit.statusline')
              return ok and sl.get_hunk() ~= nil
            end,
            color = { fg = '#e0af68' },
          },
          {
            'diff',
            symbols = { added = ' ', modified = ' ', removed = ' ' },
          },
        },
        lualine_c = {
          {
            'diagnostics',
            symbols = { error = ' ', warn = ' ', info = ' ', hint = '󰌵 ' },
          },
          { 'filename', path = 1, symbols = { modified = ' ', readonly = ' ', unnamed = '󰡯 ' } },
        },
        lualine_x = {
          {
            function()
              local reg = vim.fn.reg_recording()
              if reg ~= '' then return '󰑋 @' .. reg end
              return ''
            end,
            color = { fg = '#ff9e64' },
          },
          {
            function()
              local ok, result = pcall(vim.fn.searchcount, { maxcount = 999, timeout = 250 })
              if ok and result.total > 0 then
                return string.format(' %d/%d', result.current, result.total)
              end
              return ''
            end,
          },
          {
            function()
              local clients = vim.lsp.get_clients({ bufnr = 0 })
              if #clients == 0 then return '' end
              local names = {}
              for _, client in ipairs(clients) do
                table.insert(names, client.name)
              end
              return ' ' .. table.concat(names, ', ')
            end,
          },
          {
            'encoding',
            cond = function() return vim.opt.fileencoding:get() ~= 'utf-8' end,
          },
          {
            'fileformat',
            symbols = { unix = '', dos = '', mac = '' },
            cond = function() return vim.opt.fileformat:get() ~= 'unix' end,
          },
          { 'filetype', icon_only = true },
        },
        lualine_y = {
          { 'progress', icon = '󰦨' },
        },
        lualine_z = {
          { 'location', icon = '' },
        },
      },
      inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = { { 'filename', path = 1 } },
        lualine_x = { 'location' },
        lualine_y = {},
        lualine_z = {},
      },
      extensions = { 'neo-tree', 'lazy', 'trouble', 'quickfix', 'man' },
    },
  },
  {
    'akinsho/bufferline.nvim',
    version = '*',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    event = 'VimEnter',
    opts = {
      options = {
        show_buffer_close_icons = false,
      },
    },
  },
  {
    'folke/snacks.nvim',
    priority = 1000,
    lazy = false,
    opts = {
      indent = { enabled = true },
      notifier = { enabled = true },
      quickfile = { enabled = true },
      statuscolumn = { enabled = false },
      words = { enabled = false },
    },
  },
}
