local Component = require('ui.Component')
local Element = require('ui.elements.Element')
local View = require('ui.View')

local Popup = View:extend()

local Surface = Component({
  elements = {
    frame = {
      win_plot = { border = 'rounded', focusable = false },
      win_options = { winhl = 'Normal:TinPopup,FloatBorder:TinPopupBorder,FloatTitle:TinPopupTitle' },
    },
  },
})

function Surface:layout(spec)
  return spec.view(self.elements.frame, { zindex = 60 })
end

function Surface:with_element(fn)
  for _, element in pairs(self.elements) do
    if element:is_valid() then
      local result = fn(element)
      if result then return result end
    end
  end
end

function Popup:constructor(opts)
  local instance = View.constructor(self)
  instance.opts = opts or {}
  instance.regions = {}
  instance.origin = vim.api.nvim_get_current_win()
  return instance
end

function Popup:dimensions()
  return math.max(20, math.min(self.opts.width or 84, vim.o.columns - 6)),
    math.max(6, math.min(self.opts.height or 16, vim.o.lines - 6))
end

function Popup:create()
  local links = {
    TinPopup = 'NormalFloat',
    TinPopupBorder = 'FloatBorder',
    TinPopupTitle = 'Title',
    TinPopupMuted = 'Comment',
    TinPopupAccent = 'Special',
    TinPopupSelected = 'PmenuSel',
    TinPopupChip = 'PmenuSel',
    TinPopupError = 'DiagnosticError',
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  self.surface = Surface({})
  local width, height = self:dimensions()
  self:_render({ component = self.surface, width = width, height = height, mode = 'popup' })
  self.surface.elements.frame:get_window():set_config({
    title = '  ' .. (self.opts.title or '') .. '  ',
    title_pos = 'left',
  })
  self.resize = vim.api.nvim_create_autocmd('VimResized', {
    callback = function()
      if self._destroyed then return end
      local w, h = self:dimensions()
      self.surface.elements.frame:get_window():set_config({
        width = w,
        height = h,
        row = math.floor((vim.o.lines - h - 2) / 2),
        col = math.floor((vim.o.columns - w - 2) / 2),
      })
      for _, region in pairs(self.regions) do
        self:_position(region)
      end
      if self.opts.on_resize then self.opts.on_resize() end
    end,
  })
  return self
end

function Popup:_position(region)
  local frame = self.surface.elements.frame
  local position = frame:get_window():get_position()
  local width, height = frame:get_width(), frame:get_height()
  local bounds = region.bounds(width, height)
  local plot = {
    relative = 'editor',
    row = position[1] + 1 + bounds.row,
    col = position[2] + 1 + (bounds.col or 2),
    width = math.max(1, bounds.width or width - 4),
    height = math.max(1, bounds.height),
    style = 'minimal',
    zindex = 61,
  }
  region.element:apply_layout_win_plot(plot)
  if region.element:is_valid() then region.element:get_window():set_config(plot) end
end

function Popup:element(name, bounds, opts)
  opts = opts or {}
  local element = Element({
    buf_options = {
      buftype = 'nofile',
      bufhidden = 'wipe',
      buflisted = false,
      modifiable = opts.editable == true,
      filetype = opts.filetype or '',
    },
    win_options = {
      winhl = 'Normal:TinPopup,NormalNC:TinPopup,CursorLine:TinPopupSelected',
      number = false,
      relativenumber = false,
      signcolumn = 'no',
      foldcolumn = '0',
      cursorline = false,
      wrap = opts.wrap == true,
      linebreak = true,
      spell = false,
      list = false,
      scrolloff = 0,
    },
    win_plot = { border = 'none', focusable = opts.focusable ~= false },
  })
  local region = { element = element, bounds = bounds }
  self.regions[name] = region
  self.surface.elements[name] = element
  self:_position(region)
  element:mount()
  return element
end

function Popup:destroy()
  if self._destroyed then return end
  if self.resize then vim.api.nvim_del_autocmd(self.resize) end
  vim.cmd('stopinsert')
  if self.opts.on_close then self.opts.on_close() end
  View.destroy(self)
  if vim.api.nvim_win_is_valid(self.origin) then vim.api.nvim_set_current_win(self.origin) end
end

return Popup
