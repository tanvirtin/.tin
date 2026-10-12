local operation_token = require('git.core.operation_token')

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

local forbidden = { '_gen = 0', '_gen + 1', '_gen ~=', 'local gen =' }

describe('operation_token:', function()
  describe('guard against hand-rolled generation counters', function()
    it('should find lua sources to scan', function()
      assert.is_true(#lua_sources() > 0)
    end)

    it('should not contain raw generation counter idioms', function()
      local offenders = {}

      for _, path in ipairs(lua_sources()) do
        local relative = path:sub(#git_lua + 6)

        for _, line in ipairs(vim.fn.readfile(path)) do
          for _, idiom in ipairs(forbidden) do
            if line:find(idiom, 1, true) then offenders[#offenders + 1] = relative .. ': ' .. line end
          end
        end
      end

      eq({}, offenders)
    end)

    it('should guard every async stale check with the shared helper', function()
      local guarded = {}

      for _, path in ipairs(lua_sources()) do
        local relative = path:sub(#git_lua + 6)
        local contents = table.concat(vim.fn.readfile(path), '\n')

        for ticket in contents:gmatch('local ticket = (.-)\n') do
          guarded[#guarded + 1] = relative .. ' captures ticket via ' .. ticket
        end
      end

      table.sort(guarded)

      eq({
        'features/screens/ProjectDiffView.lua captures ticket via operation_token.bump(self._op_token)',
        'features/screens/StashView.lua captures ticket via operation_token.bump(self._op_token)',
        'features/screens/StatusDiffView.lua captures ticket via operation_token.bump(self._op_token)',
        'features/screens/StatusDiffView.lua captures ticket via operation_token.bump(self._op_token)',
        'ui/components/PatchPreviewComponent.lua captures ticket via self._op_token.count',
      }, guarded)
    end)
  end)

  describe('new', function()
    it('should start at zero', function()
      eq(0, operation_token.new().count)
    end)

    it('should return independent tokens', function()
      local a = operation_token.new()
      local b = operation_token.new()

      operation_token.bump(a)

      eq(1, a.count)
      eq(0, b.count)
    end)
  end)

  describe('bump', function()
    it('should return the new count as a ticket', function()
      local token = operation_token.new()

      eq(1, operation_token.bump(token))
      eq(2, operation_token.bump(token))
      eq(3, operation_token.bump(token))
    end)
  end)

  describe('stale', function()
    it('should be false for the current ticket', function()
      local token = operation_token.new()
      local ticket = operation_token.bump(token)

      eq(false, operation_token.stale(token, ticket))
    end)

    it('should be true after any later bump', function()
      local token = operation_token.new()
      local ticket = operation_token.bump(token)

      operation_token.bump(token)

      eq(true, operation_token.stale(token, ticket))
    end)

    it('should stay stale once bumped', function()
      local token = operation_token.new()
      local ticket = operation_token.bump(token)

      operation_token.bump(token)
      operation_token.bump(token)

      eq(true, operation_token.stale(token, ticket))
    end)

    it('should not be stale for the newest of several tickets', function()
      local token = operation_token.new()
      local first = operation_token.bump(token)
      local second = operation_token.bump(token)

      eq(false, operation_token.stale(token, second))
      eq(true, operation_token.stale(token, first))
    end)
  end)
end)
