local lazy = require('core.lazy')

local event = lazy('core.event')
local git_repo = lazy('tingit.libgit2.git_repo')

local _is_registered = false
local _dir_watcher_registered = false
local _handle = nil

local function close_handle()
  if not _handle then return end
  pcall(function()
    _handle:stop()
  end)
  pcall(function()
    _handle:close()
  end)
  _handle = nil
end

local function _start_watcher()
  close_handle()

  if not git_repo.exists() then return end

  local git_dirname = git_repo.discover(nil, { git_dirname = true })
  if not git_dirname then return end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local ok = handle:start(git_dirname, {}, function(err, filename, ev_name)
    if err then return end
    if not filename then return end
    if filename:match('index%.lock$') then return end

    vim.schedule(function()
      event.emit('tingitChange', {
        git_dir = git_dirname,
        filename = filename,
        event_name = ev_name,
      })
    end)
  end)

  if not ok then
    handle:close()
    return
  end

  _handle = handle
end

local git_watcher = {}

function git_watcher.register_module()
  if _is_registered then return end
  _is_registered = true

  _start_watcher()

  event.on({ 'VimLeavePre' }, function()
    close_handle()
  end)

  if not _dir_watcher_registered then
    _dir_watcher_registered = true
    event.on({ 'DirChanged' }, function(args)
      if args.match ~= 'global' then return end
      git_repo.clear_cache()
      _start_watcher()
      event.emit('tingitDirChanged', {})
    end)
  end
end

function git_watcher.reset()
  close_handle()
  _is_registered = false
  _dir_watcher_registered = false
end

return git_watcher
