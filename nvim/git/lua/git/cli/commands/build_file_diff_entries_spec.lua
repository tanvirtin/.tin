local build_file_diff_entries = require('git.cli.commands.build_file_diff_entries')

local eq = assert.are.same

local source_path = debug.getinfo(1, 'S').source:sub(2)
local source_root = source_path:match('^(.*)/git/lua/.+$')
local git_lua = (source_root and source_root .. '/git/lua') or (vim.fn.getcwd() .. '/git/lua')

local function lua_sources()
  local paths = {}

  for _, path in ipairs(vim.fn.glob(git_lua .. '/**/*.lua', true, true)) do
    if not path:match('_spec%.lua$') then paths[#paths + 1] = path end
  end

  return paths
end

local function await(fn)
  local result, err, done = nil, nil, false

  vim.async.run(function()
    local ok, res = pcall(fn)
    if ok then
      result = res
    else
      err = res
    end
    done = true
  end)

  assert(
    vim.wait(2000, function()
      return done
    end, 5),
    'build_file_diff_entries timed out'
  )

  if err then error(err, 0) end

  return result
end

local function make_repo()
  local diff_calls = {}

  return {
    diff_calls = diff_calls,
    diff = function(_, spec)
      diff_calls[#diff_calls + 1] = spec
      if spec.filename == 'skip.lua' then return nil end
      return { filename = spec.filename, layout_type = spec.layout_type }
    end,
    file_lines = function(_, filename, ref)
      return { filename .. '@' .. tostring(ref) }
    end,
  }
end

describe('build_file_diff_entries:', function()
  it('should return empty for no files', function()
    eq(
      {},
      await(function()
        return build_file_diff_entries(make_repo(), {}, 'a', 'b', 'unified')
      end)
    )
  end)

  it('should read filetype from the status field', function()
    local entries = await(function()
      return build_file_diff_entries(make_repo(), {
        { filename = 'init.lua', filetype = 'lua' },
      }, 'from', 'to', 'unified')
    end)

    eq(1, #entries)
    eq('lua', entries[1].filetype)
  end)

  it('should ignore a get_filetype method and fall back to text', function()
    local entries = await(function()
      return build_file_diff_entries(make_repo(), {
        {
          filename = 'a.txt',
          get_filetype = function()
            return 'lua'
          end,
        },
      }, 'from', 'to', 'unified')
    end)

    eq('text', entries[1].filetype)
  end)

  it('should default filetype to text when absent', function()
    local entries = await(function()
      return build_file_diff_entries(make_repo(), {
        { filename = 'a.txt' },
      }, 'from', 'to', 'unified')
    end)

    eq('text', entries[1].filetype)
  end)

  it('should prefer the old filename for original lines', function()
    local entries = await(function()
      return build_file_diff_entries(make_repo(), {
        { filename = 'new.lua', old_filename = 'old.lua', filetype = 'lua' },
      }, 'from', 'to', 'unified')
    end)

    eq('old.lua@from', entries[1].original_lines[1])
    eq('new.lua@to', entries[1].current_lines[1])
  end)

  it('should skip files without a diff and keep the rest in order', function()
    local entries = await(function()
      return build_file_diff_entries(make_repo(), {
        { filename = 'a.lua' },
        { filename = 'skip.lua' },
        { filename = 'b.lua' },
      }, 'from', 'to', 'unified')
    end)

    eq(2, #entries)
    eq('a.lua', entries[1].filename)
    eq('b.lua', entries[2].filename)
  end)

  it('should pass the range refs and layout through to diff', function()
    local repo = make_repo()

    await(function()
      return build_file_diff_entries(repo, { { filename = 'a.lua' } }, 'HEAD~1', 'HEAD', 'split')
    end)

    eq(1, #repo.diff_calls)
    eq('range', repo.diff_calls[1].type)
    eq('HEAD~1', repo.diff_calls[1].from)
    eq('HEAD', repo.diff_calls[1].to)
    eq('split', repo.diff_calls[1].layout_type)
  end)

  it('should carry the status object through', function()
    local status = { filename = 'a.lua', filetype = 'lua' }

    local entries = await(function()
      return build_file_diff_entries(make_repo(), { status }, 'from', 'to', 'unified')
    end)

    eq(status, entries[1].status)
  end)
end)
describe('build_file_diff_entries: entry construction is not re-forked', function()
  it('should find lua sources to scan', function()
    assert.is_true(#lua_sources() > 0)
  end)

  it('should build diff file entries in exactly one place', function()
    local builders = {}

    for _, path in ipairs(lua_sources()) do
      local contents = table.concat(vim.fn.readfile(path), '\n')

      if contents:find('original_lines = repo:file_lines', 1, true) then
        builders[#builders + 1] = path:sub(#git_lua + 6)
      end
    end

    table.sort(builders)
    eq({ 'cli/commands/build_file_diff_entries.lua' }, builders)
  end)

  it('should not probe a get_filetype method on status objects', function()
    local offenders = {}

    for _, path in ipairs(lua_sources()) do
      local contents = table.concat(vim.fn.readfile(path), '\n')

      if contents:find('get_filetype and', 1, true) then offenders[#offenders + 1] = path:sub(#git_lua + 6) end
    end

    eq({}, offenders)
  end)
end)
