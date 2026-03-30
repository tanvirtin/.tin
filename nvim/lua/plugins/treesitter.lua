local config = require('config')

return {
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    lazy = false,
    config = function()
      require('nvim-treesitter.configs').setup({
        ensure_installed = config.treesitter_languages,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        indent = {
          enable = true,
        },
      })

      -- Fix Neovim 0.12 crash: #set-lang-from-info-string! in markdown
      -- injection query triggers 'attempt to call method range (a nil value)'.
      vim.treesitter.query.set('markdown', 'injections', [[
        (fenced_code_block
          (info_string
            (language) @injection.language)
          (code_fence_content) @injection.content)

        ((html_block) @injection.content
          (#set! injection.language "html")
          (#set! injection.combined)
          (#set! injection.include-children))

        ((minus_metadata) @injection.content
          (#set! injection.language "yaml")
          (#offset! @injection.content 1 0 -1 0)
          (#set! injection.include-children))

        ((plus_metadata) @injection.content
          (#set! injection.language "toml")
          (#offset! @injection.content 1 0 -1 0)
          (#set! injection.include-children))

        ([
          (inline)
          (pipe_table_cell)
        ] @injection.content
          (#set! injection.language "markdown_inline"))
      ]])
    end,
  },
}
