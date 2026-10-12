local lazy = require('core.lazy')

local env = lazy('core.env')
local event = lazy('core.event')
local keymap = lazy('core.keymap')
local console = lazy('core.console')
local sign = lazy('git.core.sign')
local libgit2 = lazy('git.libgit2')
local renderer = lazy('core.renderer')
local settings = lazy('core.settings')
local highlight = lazy('core.highlight')
local router = lazy('git.cli.router')
local hls_setting = lazy('git.settings.hls')
local git_setting = lazy('git.settings.git')
local git_watcher = lazy('git.git.git_watcher')
local Hunks = lazy('git.features.buffer.Hunks')
local hunks_setting = lazy('git.settings.hunks')
local scene_setting = lazy('git.settings.scene')
local signs_setting = lazy('git.settings.signs')
local git_porcelain = lazy('git.cli.GitPorcelain')
local symbols_setting = lazy('git.settings.symbols')
local libgit2_setting = lazy('git.settings.libgit2')
local display_service = lazy('git.ui.display_service')
local Conflicts = lazy('git.features.buffer.Conflicts')
local LiveBlame = lazy('git.features.buffer.LiveBlame')
local hunk_lens_setting = lazy('git.settings.hunk_lens')
local git_buffer_store = lazy('git.git.git_buffer_store')
local LiveGutter = lazy('git.features.buffer.LiveGutter')
local live_blame_setting = lazy('git.settings.live_blame')
local live_gutter_setting = lazy('git.settings.live_gutter')
local LiveConflict = lazy('git.features.buffer.LiveConflict')
local file_diff_view_setting = lazy('git.settings.file_diff_view')
local status_diff_view_setting = lazy('git.settings.status_diff_view')
local project_diff_view_setting = lazy('git.settings.project_diff_view')
local worktree_view_setting = lazy('git.settings.worktree_view')

local hunks = Hunks()
local conflicts = Conflicts()
local live_blame = LiveBlame()
local live_gutter = LiveGutter()
local live_conflict = LiveConflict()

local controls = {
  hunk_up = event.async(function()
    hunks:hunk_up()
    conflicts:hunk_up()
  end),
  hunk_down = event.async(function()
    hunks:hunk_down()
    conflicts:hunk_down()
  end),
}

local buffer = {
  reset = event.async(function()
    hunks:reset_all()
  end),
  stage = event.async(function()
    hunks:stage_all()
  end),
  unstage = event.async(function()
    hunks:unstage_all()
  end),
  hunk_stage = event.async(function()
    hunks:cursor_stage()
  end),
  hunk_reset = event.async(function()
    hunks:cursor_reset()
  end),
  conflict_accept_both = event.async(function()
    conflicts:accept_both()
  end),
  conflict_accept_current = event.async(function()
    conflicts:accept_current()
  end),
  conflict_accept_incoming = event.async(function()
    conflicts:accept_incoming()
  end),
}

local toggle_diff_preference = event.async(function()
  display_service.toggle_diff_preference()
end)

local toggle_live_blame = event.async(function()
  local blames_enabled = live_blame_setting:get('enabled')
  if blames_enabled then live_blame:cleanup() end

  live_blame_setting:set('enabled', not blames_enabled)
  live_blame:reset()
end)

local toggle_live_gutter = event.async(function()
  local live_gutter_enabled = live_gutter_setting:get('enabled')
  if live_gutter_enabled then live_gutter:cleanup() end

  live_gutter_setting:set('enabled', not live_gutter_enabled)
  live_gutter:toggle()
end)

local function help()
  if display_service.help() then return end
  vim.notify('Git: no help documentation available', vim.log.levels.INFO)
end

local function cleanup()
  console.cleanup()
  live_blame:cleanup()
  live_gutter:cleanup()
  live_conflict:cleanup()
  display_service.reset()
end

local function register_modules()
  env.register_module()

  highlight.register_module(function()
    sign.register_module()
  end)
  renderer.register_module()

  local _, err = libgit2.register_module()
  if err then console.error(err) end

  git_watcher.register_module()
end

local function register_events()
  display_service.register_events()
  live_blame:register_events()
  live_gutter:register_events()
  highlight.register_events()
  git_buffer_store.register_events()
  live_conflict:register_events()
end

local function register_keymaps(config)
  local keymaps = config and config.keymaps or {}
  keymap.define(keymaps)
end

local function configure_settings(config)
  local config_settings = config and config.settings or {}

  settings.register('symbols', require('git.settings.symbols'))
  settings.register('signs', require('git.settings.signs'))
  settings.register('hls', require('git.settings.hls'))
  settings.register('scene', require('git.settings.scene'))
  settings.register('hunks', require('git.settings.hunks'))
  settings.register('live_gutter', require('git.settings.live_gutter'))

  hunks_setting:assign(config_settings.hunks)

  git_setting:assign(config_settings.git)
  hls_setting:assign(config_settings.hls)
  signs_setting:assign(config_settings.signs)
  scene_setting:assign(config_settings.scene)
  libgit2_setting:assign(config_settings.libgit2)
  symbols_setting:assign(config_settings.symbols)
  hunk_lens_setting:assign(config_settings.hunk_lens)
  live_blame_setting:assign(config_settings.live_blame)
  live_gutter_setting:assign(config_settings.live_gutter)
  file_diff_view_setting:assign(config_settings.file_diff_view)
  status_diff_view_setting:assign(config_settings.status_diff_view)
  project_diff_view_setting:assign(config_settings.project_diff_view)
  worktree_view_setting:assign(config_settings.worktree_view)
end

local controller = {}

local setup_done = false

function controller.setup(config)
  if setup_done then return end
  setup_done = true

  configure_settings(config)

  vim.api.nvim_create_user_command('G', controller.execute_command, {
    nargs = '*',
    complete = controller.autocomplete,
  })

  register_modules()
  register_events()
  register_keymaps(config)

  event.on({ 'VimLeavePre' }, function()
    cleanup()
  end)
end

function controller.commands()
  return {
    help = help,
    setup = controller.setup,
    toggle_live_blame = toggle_live_blame,
    toggle_live_gutter = toggle_live_gutter,
    toggle_diff_preference = toggle_diff_preference,
    hunk_up = controls.hunk_up,
    hunk_down = controls.hunk_down,
    buffer_reset = buffer.reset,
    buffer_stage = buffer.stage,
    buffer_unstage = buffer.unstage,
    buffer_hunk_reset = buffer.hunk_reset,
    buffer_hunk_stage = buffer.hunk_stage,
    buffer_conflict_accept_both = buffer.conflict_accept_both,
    buffer_conflict_accept_current = buffer.conflict_accept_current,
    buffer_conflict_accept_incoming = buffer.conflict_accept_incoming,
  }
end

controller.execute_command = event.async(function(args)
  local fargs = args and args.fargs or {}

  if #fargs == 0 then
    router.execute({ 'status' })
    return
  end

  local cmd = fargs[1]

  local porcelain_commands = {}
  for _, name in ipairs(router.commands()) do
    porcelain_commands[name] = true
  end

  if porcelain_commands[cmd] then
    router.execute(fargs)
    return
  end

  local commands = controller.commands()
  local cmd_func = commands[cmd]

  if cmd_func then
    cmd_func(unpack(fargs, 2))
    return
  end

  vim.notify(string.format('Git: Unknown command "%s"', cmd), vim.log.levels.ERROR)
end)

function controller.autocomplete(arg_lead, cmd_line, _)
  local split_cmd = vim.split(cmd_line, '%s+')

  if #split_cmd == 2 then
    local commands = controller.commands()
    local all_commands = vim.tbl_keys(commands)

    vim.list_extend(all_commands, router.commands())

    return vim.tbl_filter(function(cmd)
      return vim.startswith(cmd, arg_lead)
    end, all_commands)
  end

  local cmd = split_cmd[2]
  if cmd == 'debug' then
    local subcommands = { 'on', 'off', 'status', 'open' }
    return vim.tbl_filter(function(sub)
      return vim.startswith(sub, arg_lead)
    end, subcommands)
  end

  if cmd == 'diff' or cmd == 'blame' or cmd == 'hunk' then
    local porcelain = git_porcelain()
    local command_def = porcelain:get_command(cmd)
    if command_def and command_def.options then
      local options = {}
      for opt_name, _ in pairs(command_def.options) do
        table.insert(options, '--' .. opt_name:gsub('_', '-'))
      end
      return vim.tbl_filter(function(opt)
        return vim.startswith(opt, arg_lead)
      end, options)
    end
  end

  return {}
end

return controller.commands()
