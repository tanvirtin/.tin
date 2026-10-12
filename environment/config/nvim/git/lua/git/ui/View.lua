local lazy = require('core.lazy')
local settings = require('core.settings')

local View = lazy('ui.View')
local keymap = lazy('core.keymap')
local event = lazy('core.event')
local navigation = lazy('git.core.navigation')
local statusline = lazy('git.core.statusline_state')
local scene_setting = settings.get('scene')
local hunks_setting = settings.get('hunks')

local GitView = View:extend()

function GitView:_setup_quit_keymap()
  local scene_keymaps = scene_setting:get('keymaps')
  if not scene_keymaps or not scene_keymaps.quit then return end
  local quit_key = keymap.get_key(scene_keymaps.quit)
  if not quit_key then return end
  self:set_keymap({ {
    mode = 'n',
    key = quit_key,
    handler = function()
      self:destroy()
    end,
  } })
end

function GitView:_setup_hunk_navigation_keymaps()
  local hunks_keymaps = hunks_setting:get('keymaps')
  if not hunks_keymaps then return end
  local down_key = keymap.get_key(hunks_keymaps.down)
  if down_key then
    self:set_keymap({ { mode = 'n', key = down_key, handler = event.async(function()
      self:hunk_down()
    end) } })
  end
  local up_key = keymap.get_key(hunks_keymaps.up)
  if up_key then
    self:set_keymap({ { mode = 'n', key = up_key, handler = event.async(function()
      self:hunk_up()
    end) } })
  end
end

function GitView:on_git_change() end

function GitView:get_navigatable_component()
  if self._layout_type == 'split' then return self._current_component end
  if self._patch_component then return self._patch_component end
  return nil
end

function GitView:get_hunk_alignment()
  return 'center'
end
function GitView:get_hunk_alignment_offset()
  return 0
end

function GitView:_get_all_diff_components()
  if self._layout_type == 'split' then
    local components = {}
    if self._previous_component then components[#components + 1] = self._previous_component end
    if self._current_component then components[#components + 1] = self._current_component end
    return components
  end
  if self._patch_component then return { self._patch_component } end
  return {}
end

function GitView:_set_keymap_all_components(mode, key, handler)
  for _, component in ipairs(self:_get_all_diff_components()) do
    if component and component:is_valid() then component:set_keymap({ mode = mode, key = key }, handler) end
  end
end

function GitView:_set_hunk_entries(hunk_entries)
  if self._layout_type == 'split' then
    if self._previous_component and self._previous_component:is_valid() then
      local previous_entries = {}
      for _, entry in ipairs(hunk_entries) do
        previous_entries[#previous_entries + 1] = vim.tbl_extend('force', entry, { buftype = 'previous' })
      end
      self._previous_component:set_props({ hunk_entries = previous_entries })
    end
    if self._current_component and self._current_component:is_valid() then
      local current_entries = {}
      for _, entry in ipairs(hunk_entries) do
        current_entries[#current_entries + 1] = vim.tbl_extend('force', entry, { buftype = 'current' })
      end
      self._current_component:set_props({ hunk_entries = current_entries })
    end
  else
    if self._patch_component and self._patch_component:is_valid() then
      self._patch_component:set_props({ hunk_entries = hunk_entries })
    end
  end
end

function GitView:get_current_mark_index()
  local component = self:get_navigatable_component()
  if not component then return nil, 0 end
  return navigation.get_mark_index(component:get_marks(), component:get_lnum())
end

function GitView:hunk_up()
  local component = self:get_navigatable_component()
  if not component or not component:is_valid() then return end
  component:hunk_up(self:get_hunk_alignment(), self:get_hunk_alignment_offset())
  local index, count = self:get_current_mark_index()
  if index then statusline.set_hunk({ index = index, count = count }) end
end

function GitView:hunk_down()
  local component = self:get_navigatable_component()
  if not component or not component:is_valid() then return end
  component:hunk_down(self:get_hunk_alignment(), self:get_hunk_alignment_offset())
  local index, count = self:get_current_mark_index()
  if index then statusline.set_hunk({ index = index, count = count }) end
end

function GitView:_create_diff_component(opts, layout_type)
  local DiffComponent = require('git.ui.components.DiffComponent')
  local SplitDiffComponent = require('git.ui.components.SplitDiffComponent')

  opts = opts or {}
  local props = {
    diff = opts.diff,
    filename = opts.filename,
    filetype = opts.filetype or 'text',
  }

  if layout_type == 'split' then return SplitDiffComponent(props) end
  return DiffComponent(props)
end

return GitView
