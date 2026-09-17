local M = {}

function M.new(opts)
  local self = { name = opts.name, directory = opts.directory, jobs = {}, closed = false }

  function self:argv(action, args, directory)
    local command = { opts.bin or 'tin', 'agent', action }
    vim.list_extend(command, args or {})
    if self.name then vim.list_extend(command, { '--server', self.name }) end
    if directory or self.directory then vim.list_extend(command, { '--directory', directory or self.directory }) end
    if action ~= 'group' then
      assert(opts.group, 'Open Neovim in a Tin worktree group first.')
      vim.list_extend(command, { '--group', opts.group })
    end
    return command
  end

  function self:call(action, args, input, callback, directory)
    if self.closed then return end
    if action ~= 'group' and not opts.group then return callback(nil, 'Open Neovim in a Tin worktree group first.') end
    local token = {}
    self.jobs[token] = true
    local ok, job = pcall(
      vim.system,
      self:argv(action, args, directory),
      { text = true, stdin = input, timeout = action == 'stop' and 120000 or 45000 },
      function(result)
        vim.schedule(function()
          self.jobs[token] = nil
          if self.closed then return end
          local decoded, value =
            pcall(vim.json.decode, result.stdout or '', { luanil = { object = true, array = true } })
          if not decoded then value = nil end
          if result.code ~= 0 then
            local message = vim.trim(result.stderr or '')
            if type(value) == 'table' and value.errors then message = table.concat(value.errors, '\n') end
            return callback(value, message ~= '' and message or 'Tin exited with status ' .. result.code)
          end
          if value == nil then
            return callback(nil, 'Tin returned unexpected output for this request.')
          end
          callback(value)
        end)
      end
    )
    if ok then
      self.jobs[token] = job
    else
      self.jobs[token] = nil
      vim.schedule(function()
        if not self.closed then callback(nil, 'Could not start Tin: ' .. tostring(job)) end
      end)
    end
  end

  function self:close()
    self.closed = true
    for _, job in pairs(self.jobs) do
      if type(job) == 'table' and job.kill then job:kill(15) end
    end
    self.jobs = {}
  end

  return self
end

return M
