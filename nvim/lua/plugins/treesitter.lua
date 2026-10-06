local config = require('config')

return {
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    lazy = false,
    config = function()
      require('nvim-treesitter').setup({
        install_dir = vim.fn.stdpath('data') .. '/site',
      })
      require('nvim-treesitter').install(config.treesitter_languages)

      vim.api.nvim_create_autocmd('FileType', {
        callback = function()
          local lang = vim.treesitter.language.get_lang(vim.bo.filetype)
          if lang and vim.treesitter.language.add(lang) then
            vim.treesitter.start()
            vim.bo.indentexpr = 'v:lua.require\'nvim-treesitter\'.indentexpr()'
          end
        end,
      })

      vim.treesitter.query.set(
        'markdown',
        'injections',
        [[
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
      ]]
      )
    end,
  },
}
