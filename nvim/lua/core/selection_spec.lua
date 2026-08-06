local selection = require('core.selection')

local eq = assert.are.same

describe('selection:', function()
  describe('new', function()
    it('should construct a selection with line range', function()
      local s = selection.new('src/main.zig', 10, 25)

      eq(s.file, 'src/main.zig')
      eq(s.start_line, 10)
      eq(s.end_line, 25)
      eq(s.start_col, nil)
      eq(s.end_col, nil)
    end)

    it('should construct a selection with columns', function()
      local s = selection.new('src/main.zig', 10, 25, 5, 12)

      eq(s.file, 'src/main.zig')
      eq(s.start_line, 10)
      eq(s.end_line, 25)
      eq(s.start_col, 5)
      eq(s.end_col, 12)
    end)

    it('should normalize reversed line range', function()
      local s = selection.new('src/main.zig', 25, 10)

      eq(s.start_line, 10)
      eq(s.end_line, 25)
    end)

    it('should normalize reversed columns on same line', function()
      local s = selection.new('src/main.zig', 10, 10, 20, 5)

      eq(s.start_col, 5)
      eq(s.end_col, 20)
    end)

    it('should swap columns when lines are reversed', function()
      local s = selection.new('src/main.zig', 25, 10, 12, 5)

      eq(s.start_line, 10)
      eq(s.end_line, 25)
      eq(s.start_col, 5)
      eq(s.end_col, 12)
    end)

    it('should handle single line selection', function()
      local s = selection.new('src/main.zig', 10, 10)

      eq(s.start_line, 10)
      eq(s.end_line, 10)
    end)
  end)

  describe('relative_path', function()
    it('should strip root prefix from absolute path', function()
      local result = selection.relative_path('/home/user/project/src/main.zig', '/home/user/project')

      eq(result, 'src/main.zig')
    end)

    it('should handle root with trailing slash', function()
      local result = selection.relative_path('/home/user/project/src/main.zig', '/home/user/project/')

      eq(result, 'src/main.zig')
    end)

    it('should return filename when path equals root plus file', function()
      local result = selection.relative_path('/home/user/project/init.lua', '/home/user/project')

      eq(result, 'init.lua')
    end)

    it('should handle deeply nested paths', function()
      local result = selection.relative_path('/a/b/c/d/e/f.lua', '/a/b')

      eq(result, 'c/d/e/f.lua')
    end)

    it('should return the path unchanged when root does not match', function()
      local result = selection.relative_path('/other/path/file.lua', '/home/user/project')

      eq(result, '/other/path/file.lua')
    end)
  end)

  describe('format', function()
    it('should format line-wise single line', function()
      local s = selection.new('src/main.zig', 10, 10)

      eq(selection.format(s), 'src/main.zig:10')
    end)

    it('should format line-wise range', function()
      local s = selection.new('src/main.zig', 10, 25)

      eq(selection.format(s), 'src/main.zig:10-25')
    end)

    it('should format char-wise single position', function()
      local s = selection.new('src/main.zig', 10, 10, 5, 5)

      eq(selection.format(s), 'src/main.zig:10:5')
    end)

    it('should format char-wise range same line', function()
      local s = selection.new('src/main.zig', 10, 10, 5, 12)

      eq(selection.format(s), 'src/main.zig:10:5-10:12')
    end)

    it('should format char-wise range across lines', function()
      local s = selection.new('src/main.zig', 10, 25, 5, 12)

      eq(selection.format(s), 'src/main.zig:10:5-25:12')
    end)
  end)

  describe('format_many', function()
    it('should return empty string for empty list', function()
      eq(selection.format_many({}), '')
    end)

    it('should format single selection same as format', function()
      local s = selection.new('src/main.zig', 10, 25)

      eq(selection.format_many({ s }), 'src/main.zig:10-25')
    end)

    it('should group multiple ranges in same file with comma', function()
      local s1 = selection.new('src/main.zig', 10, 25)
      local s2 = selection.new('src/main.zig', 30, 40)

      eq(selection.format_many({ s1, s2 }), 'src/main.zig:10-25,30-40')
    end)

    it('should separate different files with space', function()
      local s1 = selection.new('src/main.zig', 10, 25)
      local s2 = selection.new('src/lib/fs.zig', 30, 40)

      eq(selection.format_many({ s1, s2 }), 'src/main.zig:10-25 src/lib/fs.zig:30-40')
    end)

    it('should group by file across interleaved selections with space', function()
      local s1 = selection.new('src/main.zig', 10, 25)
      local s2 = selection.new('src/lib/fs.zig', 30, 40)
      local s3 = selection.new('src/main.zig', 50, 60)

      eq(selection.format_many({ s1, s2, s3 }), 'src/main.zig:10-25,50-60 src/lib/fs.zig:30-40')
    end)

    it('should handle mixed line and char selections', function()
      local s1 = selection.new('src/main.zig', 10, 25)
      local s2 = selection.new('src/main.zig', 30, 40, 5, 12)

      eq(selection.format_many({ s1, s2 }), 'src/main.zig:10-25,30:5-40:12')
    end)
  end)

  describe('accumulator', function()
    before_each(function()
      selection.clear()
    end)

    describe('peek', function()
      it('should return empty table initially', function()
        eq(selection.peek(), {})
      end)

      it('should return a copy not a reference', function()
        local a = selection.peek()
        local b = selection.peek()

        assert.is_not.equal(rawequal(a, b), true)
      end)
    end)

    describe('clear', function()
      it('should reset accumulator to empty', function()
        selection.clear()

        eq(selection.peek(), {})
      end)
    end)
  end)
end)
