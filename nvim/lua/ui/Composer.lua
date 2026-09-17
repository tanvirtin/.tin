local Popup = require('ui.Popup')

local Composer = {}

function Composer.open(opts)
  local send_hint = 'Ctrl-S / normal Enter  send    Enter  new line'
  local self = { chips = vim.deepcopy(opts.chips or {}), selected = 1, busy = false, completed = false }
  self.popup = Popup({
    title = opts.title or 'Ask about your code',
    height = 17,
    on_close = function()
      if self.completed or not opts.on_draft then return end
      if not self.input or not self.input:is_valid() then return end
      opts.on_draft(table.concat(self.input:get_lines(), '\n'), vim.deepcopy(self.chips))
    end,
    on_resize = function()
      self:render_chips()
    end,
  }):create()
  self.target = self.popup:element('target', function()
    return { row = 0, height = 1 }
  end, { focusable = false })
  self.context = self.popup:element('context', function()
    return { row = 2, height = 1 }
  end)
  self.input = self.popup:element('input', function(_, height)
    return { row = 4, height = math.max(1, height - (height < 12 and 8 or 10)) }
  end, { editable = true, wrap = true, filetype = 'tin_prompt' })
  self.preview = self.popup:element('preview', function(_, height)
    local rows = height < 12 and 1 or 4
    return { row = height - rows - 2, height = rows }
  end, { focusable = false })
  self.footer = self.popup:element('footer', function(_, height)
    return { row = height - 2, height = 2 }
  end, { focusable = false })

  function self:status(text, error)
    local help = 'Tab  context'
    if opts.on_target then help = help .. '   Ctrl-T  target' end
    if opts.allow_paste ~= false then help = help .. '   Alt-Enter  paste' end
    self.footer:set_lines({ text, help .. '   Esc  exit insert' })
    self.footer:clear_extmarks()
    self.footer:place_extmark_highlight({ row = 0, hl = error and 'TinPopupError' or 'TinPopupAccent', line_hl = true })
    self.footer:place_extmark_highlight({ row = 1, hl = 'TinPopupMuted', line_hl = true })
  end

  function self:render_chips()
    self.context:clear_extmarks()
    local chip = self.chips[self.selected]
    if not chip then
      self.context:set_lines({ 'No context attached' })
      self.context:place_extmark_highlight({ row = 0, hl = 'TinPopupMuted', line_hl = true })
      self.preview:set_lines({})
      return
    end
    local label = chip.label
    local max_width = math.max(8, self.context:get_width() - 18)
    while vim.fn.strdisplaywidth(label) > max_width do
      label = vim.fn.strcharpart(label, 1)
    end
    if label ~= chip.label then label = '…' .. label end
    local pill = '  ' .. label .. '  ×  '
    self.context:set_lines({
      pill .. (#self.chips > 1 and string.format('  %d / %d', self.selected, #self.chips) or ''),
    })
    self.context:place_extmark_highlight({ row = 0, hl = 'TinPopupChip', col_range = { from = 0, to = #pill } })
    self.preview:set_filetype(chip.filetype ~= '' and chip.filetype or 'text')
    local rows = math.max(1, self.preview:get_height())
    local source = chip.preview or {}
    local lines = {}
    for i = 1, math.min(#source, rows) do
      lines[i] = source[i]
    end
    if #source > rows and rows >= 1 then
      local hidden = #source - rows
      lines[rows] = string.format('  … %d more %s', hidden, hidden == 1 and 'line' or 'lines')
    end
    self.preview:set_lines(lines)
    self.preview:clear_extmarks()
    self.preview:place_extmark_highlight({ row = 0, hl = 'TinPopupMuted', line_hl = true })
  end

  function self:remove_chip()
    if self.busy then return end
    table.remove(self.chips, self.selected)
    self.selected = math.max(1, math.min(self.selected, #self.chips))
    self:render_chips()
  end

  function self:submit(submit)
    if self.busy then return end
    local text = table.concat(self.input:get_lines(), '\n')
    if vim.trim(text) == '' then
      self:status('Write a question before sending.', true)
      self.input:focus():start_insert()
      return
    end
    self.busy = true
    self:status('Sending…')
    opts.on_submit(text, vim.deepcopy(self.chips), submit, function(ok, err)
      if self.popup:is_destroyed() then return end
      self.busy = false
      if ok then
        self.completed = true
        self.popup:destroy()
      else
        self:status(err or 'Could not send. Your draft is still here.', true)
      end
    end)
  end

  function self:change_target()
    if self.busy or not opts.on_target then return end
    local text, chips = table.concat(self.input:get_lines(), '\n'), self.chips
    self.popup:destroy()
    vim.schedule(function()
      opts.on_target(text, chips)
    end)
  end

  self.target:set_lines({ '↗  ' .. (opts.target or '') })
  self.target:place_extmark_highlight({ row = 0, hl = 'TinPopupAccent', line_hl = true })
  self.input:set_lines(vim.split(opts.text or '', '\n', { plain = true }))
  local function placeholder()
    if self.popup:is_destroyed() then return end
    self.input:clear_extmark_texts()
    if table.concat(self.input:get_lines(), '') == '' then
      self.input:place_extmark_text({
        row = 0,
        col = 0,
        text = opts.placeholder or 'What would you like to explore?',
        hl = 'TinPopupMuted',
      })
    end
  end
  self.input:attach_to_changes({
    on_lines = function()
      vim.schedule(placeholder)
    end,
  })
  for _, element in ipairs({ self.input, self.context }) do
    for _, mode in ipairs({ 'n', 'i' }) do
      element:set_keymap(mode, '<C-s>', function()
        self:submit(true)
      end)
      if opts.allow_paste ~= false then
        element:set_keymap(mode, '<M-CR>', function()
          self:submit(false)
        end)
      end
      element:set_keymap(mode, '<C-t>', function()
        self:change_target()
      end)
    end
    for _, key in ipairs({ '<Esc>', '<C-c>' }) do
      element:set_keymap('n', key, function()
        self.popup:destroy()
      end)
    end
  end
  for _, mode in ipairs({ 'n', 'i' }) do
    self.input:set_keymap(mode, '<Tab>', function()
      self.input:stop_insert()
      self.context:focus()
      self:status('←/→  context chips    x / Delete  remove    Tab  back to question')
    end)
  end
  self.input:set_keymap('n', '<CR>', function()
    self:submit(true)
  end)
  for _, key in ipairs({ '<Tab>', '<CR>', 'i' }) do
    self.context:set_keymap('n', key, function()
      self:status(send_hint)
      self.input:focus():start_insert()
    end)
  end
  for _, key in ipairs({ 'x', '<Del>', '<BS>' }) do
    self.context:set_keymap('n', key, function()
      self:remove_chip()
    end)
  end
  for key, delta in pairs({ h = -1, l = 1, ['<Left>'] = -1, ['<Right>'] = 1 }) do
    self.context:set_keymap('n', key, function()
      if #self.chips == 0 then return end
      self.selected = (self.selected - 1 + delta) % #self.chips + 1
      self:render_chips()
    end)
  end
  self:status(send_hint)
  self:render_chips()
  placeholder()
  self.input:focus():start_insert()
  return self
end

return Composer
