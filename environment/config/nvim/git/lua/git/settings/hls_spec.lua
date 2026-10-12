local hls = require('git.settings.hls')

local function resolved_entries()
  local resolved = {}

  hls:for_each(function(name, value)
    resolved[name:lower()] = type(value) == 'function' and value() or value
  end)

  return resolved
end

describe('hls:', function()
  describe('group names', function()
    it('should not define two groups that differ only in case', function()
      local seen = {}
      local collisions = {}

      hls:for_each(function(name)
        local lower = name:lower()
        if seen[lower] then table.insert(collisions, string.format('%s vs %s', seen[lower], name)) end
        seen[lower] = name
      end)

      assert.are.same({}, collisions)
    end)

    it('should define distinct border groups for border and search popups', function()
      local names = {}
      hls:for_each(function(name)
        names[name:lower()] = name
      end)

      assert.is_not_nil(names.gitborder)
      assert.is_not_nil(names.gitlinenrborder)
    end)

    it('should resolve the border groups to different colors', function()
      local resolved = resolved_entries()

      assert.is_not_nil(resolved.gitborder)
      assert.is_not_nil(resolved.gitlinenrborder)
      assert.are_not.same(resolved.gitborder, resolved.gitlinenrborder)
    end)
  end)

  describe('unresolvable attributes', function()
    it('should not fabricate a color when a source attribute is missing', function()
      vim.api.nvim_set_hl(0, 'HlsProbeGroup', { foreground = 16711680 })
      local Color = require('core.Color')
      local color = Color({ name = 'HlsProbeGroup', attribute = 'bg' })

      assert.is_nil(color:get())
    end)
  end)
end)
