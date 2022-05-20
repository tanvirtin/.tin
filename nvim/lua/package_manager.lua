local package_manager = {}

function package_manager.install_package_manager()
  local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
  if not vim.loop.fs_stat(lazypath) then
    vim.fn.system({
      'git',
      'clone',
      '--filter=blob:none',
      'https://github.com/folke/lazy.nvim.git',
      '--branch=stable',
      lazypath,
    })
  end
  vim.opt.rtp:prepend(lazypath)
end

function package_manager.install_plugins()
  require('lazy').setup({
    'tanvirtin/monokai.nvim',
    'kyazdani42/nvim-web-devicons',
    {
      'nvim-treesitter/nvim-treesitter',
      run = ':TSUpdate',
    },
    {
      'akinsho/bufferline.nvim',
      dependencies = { 'nvim-tree/nvim-web-devicons' },
      config = function()
        require('bufferline').setup({
          options = { show_buffer_close_icons = false },
        })
      end,
    },
    {
      'nvim-telescope/telescope.nvim',
      event = 'VimEnter',
      branch = '0.1.x',
      dependencies = {
        'nvim-lua/plenary.nvim',
        {
          'nvim-telescope/telescope-fzf-native.nvim',
          build = 'make',
          cond = function()
            return vim.fn.executable('make') == 1
          end,
        },
        { 'nvim-telescope/telescope-ui-select.nvim' },
        {
          'nvim-tree/nvim-web-devicons',
          enabled = vim.g.have_nerd_font,
        },
      },
      config = function()
        require('telescope').setup({
          extensions = {
            ['ui-select'] = { require('telescope.themes').get_dropdown() },
          },
        })
        pcall(require('telescope').load_extension, 'fzf')
        pcall(require('telescope').load_extension, 'ui-select')
      end,
    },
    {
      'hrsh7th/nvim-cmp',
      dependencies = { 'hrsh7th/cmp-nvim-lsp' },
    },
    {
      'nvim-neo-tree/neo-tree.nvim',
      dependencies = {
        'MunifTanjim/nui.nvim',
        'nvim-lua/plenary.nvim',
      },
      config = function()
        vim.g.nvim_tree_quit_on_open = 1
        vim.g.nvim_tree_indent_markers = 1
        vim.g.nvim_tree_git_hl = 1
        vim.g.nvim_tree_root_folder_modifier = ':~'

        vim.cmd([[ let g:neo_tree_remove_legacy_commands = 1 ]])

        vim.fn.sign_define('DiagnosticSignError', { text = ' ', texthl = 'DiagnosticSignError' })
        vim.fn.sign_define('DiagnosticSignWarn', { text = ' ', texthl = 'DiagnosticSignWarn' })
        vim.fn.sign_define('DiagnosticSignInfo', { text = ' ', texthl = 'DiagnosticSignInfo' })
        vim.fn.sign_define('DiagnosticSignHint', { text = '', texthl = 'DiagnosticSignHint' })

        require('neo-tree').setup({
          close_if_last_window = false,
          popup_border_style = 'rounded',
          enable_git_status = true,
          enable_diagnostics = true,
          default_component_configs = {
            indent = {
              indent_size = 2,
              padding = 1,
              with_markers = true,
              indent_marker = '│',
              last_indent_marker = '└',
              highlight = 'NeoTreeIndentMarker',
              with_expanders = nil,
              expander_collapsed = '',
              expander_expanded = '',
              expander_highlight = 'NeoTreeExpander',
            },
            icon = {
              folder_closed = '',
              folder_open = '',
              folder_empty = 'ﰊ',
              default = '*',
            },
            name = {
              trailing_slash = false,
              use_git_status_colors = true,
            },
            git_status = {
              symbols = {
                added = '✚',
                deleted = '✖',
                modified = '',
                renamed = '',
                untracked = '',
                ignored = '',
                unstaged = '',
                staged = '',
                conflict = '',
              },
            },
          },
          window = {
            position = 'left',
            width = 40,
            mappings = {
              ['<space>'] = 'toggle_node',
              ['<2-LeftMouse>'] = 'open',
              ['<cr>'] = 'open',
              ['S'] = 'open_split',
              ['s'] = 'open_vsplit',
              ['C'] = 'close_node',
              ['<bs>'] = 'navigate_up',
              ['.'] = 'set_root',
              ['H'] = 'toggle_hidden',
              ['R'] = 'refresh',
              ['/'] = 'fuzzy_finder',
              ['f'] = 'filter_on_submit',
              ['<c-x>'] = 'clear_filter',
              ['a'] = 'add',
              ['A'] = 'add_directory',
              ['d'] = 'delete',
              ['r'] = 'rename',
              ['y'] = 'copy_to_clipboard',
              ['x'] = 'cut_to_clipboard',
              ['p'] = 'paste_from_clipboard',
              ['c'] = 'copy',
              ['m'] = 'move',
              ['q'] = 'close_window',
            },
          },
          nesting_rules = {},
          filesystem = {
            filtered_items = {
              visible = true,
              hide_dotfiles = false,
              hide_gitignored = false,
              hide_by_name = {
                '.DS_Store',
                'thumbs.db',
              },
              never_show = {},
            },
            follow_current_file = true,
            hijack_netrw_behavior = 'open_default',
            use_libuv_file_watcher = true,
          },
          buffers = {
            show_unloaded = true,
            window = {
              mappings = {
                ['bd'] = 'buffer_delete',
              },
            },
          },
          git_status = {
            window = {
              position = 'left',
              mappings = {
                ['A'] = 'git_add_all',
                ['gu'] = 'git_unstage_file',
                ['ga'] = 'git_add_file',
                ['gr'] = 'git_revert_file',
                ['gc'] = 'git_commit',
                ['gp'] = 'git_push',
                ['gg'] = 'git_commit_and_push',
              },
            },
          },
        })
      end,
    },
    {
      'nvim-lualine/lualine.nvim',
      event = 'VimEnter',
      config = function()
        require('lualine').setup()
      end,
      requires = { 'nvim-web-devicons' },
    },
    {
      'windwp/nvim-autopairs',
      config = function()
        require('nvim-autopairs').setup()
      end,
    },
    'nvim-lua/plenary.nvim',
    'neovim/nvim-lspconfig',
    'williamboman/mason.nvim',
    'williamboman/mason-lspconfig.nvim',
    {
      'folke/trouble.nvim',
      cmd = 'Trouble',
    },
    (function(dev)
      if dev then
        return {
          dir = '~/workspace/vgit.nvim',
          event = 'VimEnter',
          config = function()
            require('vgit').setup({
              settings = {
                scene = {
                  diff_preference = 'unified',
                  keymaps = {
                    quit = '<C-c>',
                  },
                },
              },
            })
          end,
        }
      end
      return {
        'tanvirtin/vgit.nvim',
        branch = 'develop',
        config = function()
          require('vgit').setup({
            settings = {
              scene = {
                diff_preference = 'unified',
                keymaps = {
                  quit = '<C-c>',
                },
              },
            },
          })
        end,
      }
    end)(true),
  })
end

function package_manager.setup_plugins()
  require('nvim-web-devicons').setup({
    override = {
      zsh = {
        icon = '',
        color = '#428850',
        name = 'Zsh',
      },
    },
    default = true,
  })
  require('nvim-treesitter.configs').setup({
    ensure_installed = { 'c', 'cpp', 'go', 'lua', 'python', 'rust', 'typescript', 'cmake' },
    highlight = {
      enable = true,
      additional_vim_regex_highlighting = true,
    },
  })
end

function package_manager.init()
  package_manager.install_package_manager()
  package_manager.install_plugins()
  package_manager.setup_plugins()
end

return package_manager
