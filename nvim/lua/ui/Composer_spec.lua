local Composer = require('ui.Composer')
local eq = assert.are.same

describe('Context composer', function()
  local opened, origin, windows, buffers

  before_each(function()
    opened = {}
    origin = vim.api.nvim_get_current_win()
    windows = #vim.api.nvim_list_wins()
    buffers = #vim.api.nvim_list_bufs()
  end)

  after_each(function()
    for _, ui in ipairs(opened) do
      ui.popup:destroy()
    end
    vim.wait(100, function()
      return false
    end)
    eq(windows, #vim.api.nvim_list_wins())
    eq(buffers, #vim.api.nvim_list_bufs())
    eq(origin, vim.api.nvim_get_current_win())
  end)

  local function open(opts)
    local ui = Composer.open(opts)
    opened[#opened + 1] = ui
    return ui
  end

  it('keeps the draft on delivery failure and sends only remaining context chips', function()
    local sent, attempts = nil, 0
    local ui = open({
      chips = { { label = 'a.lua:1–2' }, { label = 'b.lua:5–6' } },
      on_submit = function(text, chips, submit, done)
        attempts = attempts + 1
        sent = { text = text, chips = chips, submit = submit }
        done(false, 'Target exited')
      end,
    })
    ui:submit(true)
    eq(0, attempts)
    ui.input:set_lines({ 'Trace this call', 'and explain its caller' })
    ui:remove_chip()
    ui:submit(false)
    eq(1, attempts)
    eq('Trace this call\nand explain its caller', sent.text)
    eq('b.lua:5–6', sent.chips[1].label)
    eq(1, #sent.chips)
    assert.is_false(sent.submit)
    assert.is_false(ui.popup:is_destroyed())
    eq({ 'Trace this call', 'and explain its caller' }, ui.input:get_lines())
  end)

  it('preserves the question and chips when changing targets', function()
    local draft
    local ui = open({
      chips = { { label = 'a.lua:1–2' } },
      on_submit = function() end,
      on_target = function(text, chips)
        draft = { text, chips }
      end,
    })
    ui.input:set_lines({ 'Compare this with the other project' })
    ui:change_target()
    assert.is_true(vim.wait(1000, function()
      return draft ~= nil
    end))
    eq('Compare this with the other project', draft[1])
    eq('a.lua:1–2', draft[2][1].label)
  end)

  it('keeps Escape out of insert mode so the composer stays open', function()
    local ui = open({ chips = { { label = 'a.lua:1–2' } }, on_submit = function() end })
    local function mapped(mode, lhs)
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(ui.input:get_buffer().bufnr, mode)) do
        if mapping.lhs:lower() == lhs:lower() then return true end
      end
      return false
    end
    assert.is_false(mapped('i', '<Esc>'))
    assert.is_false(mapped('i', '<C-c>'))
    assert.is_true(mapped('n', '<Esc>'))
    assert.is_true(mapped('n', '<C-c>'))
    assert.is_true(mapped('n', '<CR>'))
  end)

  it('reports the draft on close so multiple ranges can accumulate', function()
    local saved
    local ui = open({
      chips = { { label = 'a.lua:1–2' } },
      on_submit = function() end,
      on_draft = function(text, chips)
        saved = { text = text, chips = chips }
      end,
    })
    ui.input:set_lines({ 'Keep this question' })
    ui.popup:destroy()
    assert.is_truthy(saved)
    eq('Keep this question', saved.text)
    eq('a.lua:1–2', saved.chips[1].label)
  end)

  it('does not report a draft after a successful send', function()
    local saved
    local ui = open({
      chips = { { label = 'a.lua:1–2' } },
      on_draft = function()
        saved = true
      end,
      on_submit = function(_, _, _, done)
        done(true)
      end,
    })
    ui.input:set_lines({ 'question' })
    ui:submit(true)
    assert.is_true(ui.popup:is_destroyed())
    assert.is_nil(saved)
  end)

  it('highlights the preview with the source filetype and marks truncation', function()
    local ui = open({
      chips = {
        {
          label = 'a.lua:1–9',
          filetype = 'lua',
          preview = { 'a.lua · 9 lines', '1  x', '2  y', '3  z', '4  w', '5  v' },
        },
      },
      on_submit = function() end,
    })
    eq('lua', vim.bo[ui.preview:get_buffer().bufnr].filetype)
    local lines = ui.preview:get_lines()
    assert.is_truthy(lines[#lines]:find('more lines', 1, true))
  end)

  it('keeps child windows inside the rounded frame after resizing', function()
    local ui = open({ chips = { { label = 'a.lua:1–2' } }, on_submit = function() end })
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 64, 18
    vim.api.nvim_exec_autocmds('VimResized', {})
    local frame = ui.popup.surface.elements.frame:get_window():get_config()
    for name, region in pairs(ui.popup.regions) do
      local config = region.element:get_window():get_config()
      assert.is_true(config.row >= frame.row + 1, name)
      assert.is_true(config.row + config.height <= frame.row + frame.height + 1, name)
      assert.is_true(config.col + config.width <= frame.col + frame.width + 1, name)
    end
    vim.o.columns, vim.o.lines = columns, lines
    vim.api.nvim_exec_autocmds('VimResized', {})
  end)
end)
