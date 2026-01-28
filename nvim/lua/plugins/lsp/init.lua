local mason = require('plugins.lsp.mason')

return vim.list_extend({
  {
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile' },
    dependencies = {
      'williamboman/mason.nvim',
      'williamboman/mason-lspconfig.nvim',
      'saghen/blink.cmp',
    },
    config = function()
      local servers = require('plugins.lsp.servers')
      local capabilities = require('blink.cmp').get_lsp_capabilities()
      capabilities.offset_encoding = 'utf-16'

      for server_name, server_config in pairs(servers) do
        server_config.capabilities = capabilities
        vim.lsp.config(server_name, server_config)
      end

      vim.lsp.enable(vim.tbl_keys(servers))
    end,
  },
}, mason)
