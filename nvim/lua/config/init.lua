local init = {}

init.leader = ','

init.colorscheme = 'monokai'

init.lsp_servers = {
  'ts_ls',
  'eslint',
  'html',
  'cssls',
  'lua_ls',
  'basedpyright',
  'rust_analyzer',
  'gopls',
  'jsonls',
  'graphql',
  'yamlls',
  'bashls',
}

init.mason_tools = {
  'prettier',
  'stylua',
  'ruff',
  'goimports',
  'golangci-lint',
  'stylelint',
}

init.treesitter_languages = {
  'c',
  'cpp',
  'go',
  'gomod',
  'gowork',
  'lua',
  'python',
  'rust',
  'typescript',
  'javascript',
  'tsx',
  'html',
  'css',
  'json',
  'yaml',
  'toml',
  'markdown',
  'markdown_inline',
  'cmake',
  'bash',
  'vim',
  'vimdoc',
  'graphql',
  'sql',
  'dockerfile',
}

init.formatters = {
  lua = { 'stylua' },
  python = { 'ruff_format' },
  javascript = { 'prettier' },
  javascriptreact = { 'prettier' },
  typescript = { 'prettier' },
  typescriptreact = { 'prettier' },
  json = { 'prettier' },
  jsonc = { 'prettier' },
  html = { 'prettier' },
  css = { 'prettier' },
  scss = { 'prettier' },
  markdown = { 'prettier' },
  yaml = { 'prettier' },
  rust = { 'rustfmt' },
  go = { 'goimports', 'gofmt' },
}

init.linters = {
  python = { 'ruff' },
  go = { 'golangcilint' },
  css = { 'stylelint' },
  scss = { 'stylelint' },
}

init.features = {
  format_on_save = true,
  lint_on_save = true,
  open_neo_tree_on_startup = true,
}

return init
