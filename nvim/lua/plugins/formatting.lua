local config = require('config')

return {
  {
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    opts = {
      formatters_by_ft = config.formatters,
      default_format_opts = {
        lsp_format = 'fallback',
      },
      format_on_save = config.features.format_on_save and {
        timeout_ms = 3000,
        lsp_format = 'fallback',
      } or nil,
    },
  },
}
