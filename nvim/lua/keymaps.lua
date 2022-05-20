local mappings = {}

function mappings.set(mode, key, action)
  vim.api.nvim_set_keymap(mode, key, action, {
    noremap = true,
    silent = true,
  })

  return mappings
end

function mappings.set_normal(key, action)
  return mappings.set('n', key, action)
end

function mappings.clear_keys()
  mappings.set_normal('<Space>', '<NOP>')
  mappings.set_normal(',', '<NOP>')

  return mappings
end

function mappings.register_leader_key()
  -- Set leader key
  vim.g.mapleader = ','

  return mappings
end

function mappings.register_quality_of_life_keys()
  -- Better indenting
  mappings.set('v', '<', '<gv')
  mappings.set('v', '>', '>gv')

  -- Move selected line / block of text in visual mode
  mappings.set('x', 'K', ':move \'<-2<CR>gv-gv')
  mappings.set('x', 'J', ':move \'>+1<CR>gv-gv')

  -- Centers the line as you iterate
  mappings.set_normal('n', 'nzzzv')
  mappings.set_normal('N', 'Nzzzv')

  -- Toggle window focus
  mappings.set_normal('\\', '<Cmd>winc w<CR>')

  -- Delete current buffer
  mappings.set_normal('<leader>q', '<Cmd>bp | sp | bn | bd<CR>')

  -- Delete current window
  mappings.set('v', '<leader><ESC>', '<Cmd>q<CR>')
  mappings.set_normal('<leader><ESC>', '<Cmd>q<CR>')

  -- Delete contents without putting the in a register
  mappings.set('v', '<leader>d', '"_d')
  mappings.set_normal('<leader>d', '"_d')

  -- Clean up search highlights
  mappings.set_normal('<leader>c', '<Cmd>noh<CR>')

  -- Shortcuts to save
  mappings.set_normal('<leader><leader>', '<Cmd>w<CR>')

  -- Quickfix
  mappings.set_normal('<C-w>', '<Cmd>cp<CR>')
  mappings.set_normal('<C-s>', '<Cmd>cn<CR>')

  -- Buffer navigation
  mappings.set_normal('<c-h>', '<Cmd>bp<CR>')
  mappings.set_normal('<c-l>', '<Cmd>bn<CR>')

  return mappings
end

function mappings.register_file_tree_keys()
  mappings.set_normal('<Leader><space>', '<Cmd>Neotree toggle<CR>')

  return mappings
end

function mappings.register_telescope_keys()
  mappings.set_normal('<leader>.', '<Cmd>Telescope git_status theme=get_ivy<CR>')
  mappings.set_normal('<C-p>', '<Cmd>Telescope find_files theme=get_dropdown<CR>')
  mappings.set_normal('<leader>/', '<Cmd>Telescope live_grep<CR>')
  mappings.set_normal('<leader><TAB>', '<Cmd>Telescope buffers theme=get_ivy<CR>')

  return mappings
end

function mappings.register_lsp_keys()
  mappings.set_normal(
    '<space>d',
    '<Cmd>Telescope lsp_definitions theme=get_dropdown<CR>'
  )
  mappings.set_normal(
    '<space>t',
    '<Cmd>Telescope lsp_type_definitions theme=get_dropdown<CR>'
  )
  mappings.set_normal(
    '<space>i',
    '<Cmd>Telescope lsp_implementations theme=get_dropdown<CR>'
  )
  mappings.set_normal(
    '<space>r',
    '<Cmd>Telescope lsp_references theme=get_dropdown<CR>'
  )
  mappings.set_normal(
    '<space>s',
    '<Cmd>lua vim.lsp.buf.signature_help() theme=get_dropdown<CR>'
  )
  mappings.set_normal(
    '<space>a',
    '<Cmd>Telescope lsp_code_actions theme=get_dropdown<CR>'
  )
  mappings.set_normal(
    '<space><space>',
    '<Cmd>lua vim.diagnostic.open_float(0, { scope = "line" })<CR>'
  )
  mappings.set_normal(
    '<space>j',
    '<Cmd>lua vim.diagnostic.goto_next({ wrap = true, float = true })<CR>'
  )
  mappings.set_normal(
    '<space>k',
    '<Cmd>lua vim.diagnostic.goto_prev({ wrap = true, float = true })<CR>'
  )
  mappings.set_normal('<space><leader>', '<Cmd>lua vim.lsp.buf.hover()<CR>')
  mappings.set_normal('<space>R', '<Cmd>lua vim.lsp.buf.rename()<CR>')

  return mappings
end

function mappings.register_git_keys()
  mappings.set_normal('<C-k>', '<Cmd>VGit hunk_up<CR>')
  mappings.set_normal('<C-j>', '<Cmd>VGit hunk_down<CR>')
  mappings.set_normal('<leader>gs', '<Cmd>VGit buffer_hunk_stage<CR>')
  mappings.set_normal('<leader>gr', '<Cmd>VGit buffer_hunk_reset<CR>')
  mappings.set_normal('<leader>gp', '<Cmd>VGit buffer_hunk_preview<CR>')
  mappings.set_normal('<leader>gb', '<Cmd>VGit buffer_blame_preview<CR>')
  mappings.set_normal('<leader>gp', '<Cmd>VGit buffer_hunk_preview<CR>')
  mappings.set_normal('<leader>gb', '<Cmd>VGit buffer_blame_preview<CR>')
  mappings.set_normal('<leader>gf', '<Cmd>VGit buffer_diff_preview<CR>')
  mappings.set_normal('<leader>gh', '<Cmd>VGit buffer_history_preview<CR>')
  mappings.set_normal('<leader>gu', '<Cmd>VGit buffer_reset<CR>')
  mappings.set_normal('<leader>gg', '<Cmd>VGit buffer_gutter_blame_preview<CR>')
  mappings.set_normal('<leader>glu', '<Cmd>VGit project_hunks_preview<CR>')
  mappings.set_normal(
    '<leader>gls',
    '<Cmd>VGit project_hunks_staged_preview<CR>'
  )
  mappings.set_normal('<leader>gd', '<Cmd>VGit project_diff_preview<CR>')
  mappings.set_normal('<leader>gq', '<Cmd>VGit project_hunks_qf<CR>')
  mappings.set_normal('<leader>gx', '<Cmd>VGit toggle_diff_preference<CR>')

  return mappings
end

function mappings.init()
  mappings
      :clear_keys()
      :register_leader_key()
      :register_quality_of_life_keys()
      :register_file_tree_keys()
      :register_telescope_keys()
      :register_lsp_keys()
      :register_git_keys()

  return mappings
end

return mappings
