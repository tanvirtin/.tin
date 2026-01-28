return {
  ts_ls = {
    settings = {
      completion = {
        completionFunctionCalls = true,
      },
    },
  },
  eslint = {},
  html = {},
  cssls = {},
  lua_ls = {
    settings = {
      Lua = {
        workspace = { checkThirdParty = false },
        telemetry = { enable = false },
        diagnostics = {
          globals = {
            'vim',
            'describe',
            'it',
            'before_each',
            'before_all',
            'after_each',
            'after_all',
            'use',
          },
        },
      },
    },
  },
  basedpyright = {
    settings = {
      python = {
        analysis = {
          autoImportCompletions = true,
          diagnosticMode = 'openFilesOnly',
          typeCheckingMode = 'off',
          useLibraryCodeForTypes = true,
        },
      },
    },
  },
  rust_analyzer = {
    settings = {
      ['rust-analyzer'] = {
        checkOnSave = {
          command = 'clippy',
        },
      },
    },
  },
  gopls = {
    settings = {
      gopls = {
        analyses = {
          unusedparams = true,
        },
        staticcheck = true,
        gofumpt = true,
      },
    },
  },
  jsonls = {
    settings = {
      json = {
        validate = { enable = true },
      },
    },
  },
  graphql = {
    filetypes = { 'graphql', 'gql' },
  },
  yamlls = {
    settings = {
      yaml = {
        schemaStore = { enable = true },
        validate = true,
      },
    },
  },
  bashls = {
    filetypes = { 'sh', 'bash', 'zsh' },
  },
}
