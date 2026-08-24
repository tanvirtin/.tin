local Spawn = require('core.Spawn')

local eq = assert.are.same

describe('Spawn:', function()
  describe('constructor', function()
    it('should construct Spawn with specifications', function()
      Spawn({
        command = 'ls',
        args = { '-l' },
        on_stderr = function() end,
        on_stdout = function() end,
        on_exit = function() end,
      })
    end)
  end)

  describe('line processing', function()
    it('handles split chunks and empty lines', function()
      local spawn = Spawn({
        command = 'echo',
        args = { 'test' },
        on_stdout = function() end,
        on_stderr = function() end,
        on_exit = function() end,
      })

      local output = {}

      spawn:process_chunk('line1\nline2\nline3', spawn.stdout_buffer, function(line)
        table.insert(output, line)
      end)
      spawn:process_chunk('\nline4', spawn.stdout_buffer, function(line)
        table.insert(output, line)
      end)
      spawn:process_chunk('\nline5\nline6\n', spawn.stdout_buffer, function(line)
        table.insert(output, line)
      end)

      eq(output, {
        'line1',
        'line2',
        'line3',
        'line4',
        'line5',
        'line6',
      })
    end)
  end)

  describe('start', function()
    it('spawns process and pipes stdout', function()
      local stdout = {}
      local exited = false

      Spawn({
        command = 'ls',
        args = { '-l' },
        on_stderr = function() end,
        on_stdout = function(line)
          if line ~= '' then table.insert(stdout, line) end
        end,
        on_exit = function()
          exited = true
        end,
      }):start()

      vim.wait(5000, function()
        return exited
      end, 50)
      assert.is_true(exited, 'on_exit should have been called')
      assert.is_true(#stdout > 0, 'should have received stdout output')
    end)

    it('pipes stderr correctly', function()
      local stderr = {}
      local exited = false

      Spawn({
        command = 'ls',
        args = { '-invalid-flag' },
        on_stderr = function(line)
          if line ~= '' then table.insert(stderr, line) end
        end,
        on_stdout = function() end,
        on_exit = function()
          exited = true
        end,
      }):start()

      vim.wait(5000, function()
        return exited
      end, 50)
      assert.is_true(exited, 'on_exit should have been called')
      assert.is_true(#stderr > 0, 'should have received stderr output')
    end)
  end)

  describe('write', function()
    it('round-trips data through stdin', function()
      local echoed = {}

      local spawn = Spawn({
        command = 'sh',
        args = { '-c', 'while IFS= read -r line; do printf "%s\\n" "$line"; done' },
        on_stdout = function(line)
          if line ~= '' then table.insert(echoed, line) end
        end,
        on_stderr = function() end,
        on_exit = function() end,
      }):start()

      spawn:write('ping\n')

      vim.wait(5000, function()
        return #echoed >= 1
      end, 50)

      assert.is_true(#echoed >= 1, 'expected echoed stdin data')
      eq({ 'ping' }, echoed)

      spawn:stop()
      vim.wait(500, function()
        return true
      end, 10)
    end)
  end)
end)
