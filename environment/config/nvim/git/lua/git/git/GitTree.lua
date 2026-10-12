local lazy = require('core.lazy')

local Object = lazy('core.Object')
local git_log = lazy('git.git.git_log')
local git_show = lazy('git.git.git_show')
local git_repo = lazy('git.git.git_repo')
local git_hunks = lazy('git.git.git_hunks')
local git_status = lazy('git.git.git_status')

local GitTree = Object:extend()

function GitTree:constructor(repository, commit)
  if not repository then error('GitTree requires a repository') end

  if not commit then error('GitTree requires a commit reference') end

  local tree = {
    ['$_repository'] = repository,
    ['$_repo_path'] = repository:get_path(),
    ['$_commit_ref'] = commit,
    _commit_data = nil,
    _parent_tree = nil,
    _files = nil,
    _author = nil,
    _timestamp = nil,
    _message = nil,
  }

  return tree
end

function GitTree:ref()
  return self._commit_ref
end

function GitTree:commit()
  if not self._commit_data then
    local log, err = git_log.get(self._repo_path, self._commit_ref)
    if err then return nil, err end
    self._commit_data = log
  end
  return self._commit_data, nil
end

function GitTree:hash()
  local commit, err = self:commit()
  if err then return nil, err end
  return commit.commit_hash, nil
end

function GitTree:parent_hash()
  local commit, err = self:commit()
  if err then return nil, err end
  return commit.parent_hash, nil
end

function GitTree:parent()
  if not self._parent_tree then
    local parent_hash, err = self:parent_hash()
    if err then return nil, err end

    if not parent_hash or parent_hash == '' then return nil, { 'commit has no parent' } end

    self._parent_tree = GitTree(self._repository, parent_hash)
  end
  return self._parent_tree, nil
end

function GitTree:author()
  if self._author then return self._author, nil end

  local commit, err = self:commit()
  if err then return nil, err end

  self._author = {
    name = commit.author_name,
    email = commit.author_email,
  }
  return self._author, nil
end

function GitTree:timestamp()
  if self._timestamp then return self._timestamp, nil end

  local commit, err = self:commit()
  if err then return nil, err end
  self._timestamp = tonumber(commit.timestamp)
  return self._timestamp, nil
end

function GitTree:message()
  if self._message then return self._message, nil end

  local commit, err = self:commit()
  if err then return nil, err end
  self._message = commit.summary
  return self._message, nil
end

function GitTree:file(filename)
  if not filename then return nil, { 'filename is required' } end

  return git_show.lines(self._repo_path, filename, self._commit_ref)
end

function GitTree:has_file(filename)
  if not filename then return nil, { 'filename is required' } end

  return git_repo.has(self._repo_path, filename, self._commit_ref)
end

function GitTree:files()
  if not self._files then
    local commit, err = self:commit()
    if err then return nil, err end

    local parent_hash = commit.parent_hash or ''
    local files, status_err = git_status.tree(self._repo_path, {
      commit_hash = commit.commit_hash,
      parent_hash = parent_hash,
    })

    if status_err then return nil, status_err end
    self._files = files
  end

  return self._files, nil
end

function GitTree:diff(other_tree, opts)
  opts = opts or {}

  local other_ref
  if type(other_tree) == 'string' then
    other_ref = other_tree
  elseif type(other_tree) == 'table' and other_tree.ref then
    other_ref = other_tree:ref()
  else
    return nil, { 'other_tree must be a GitTree or commit reference' }
  end

  local current_hash, err = self:hash()
  if err then return nil, err end

  return git_hunks.list(self._repo_path, {
    current = current_hash,
    parent = other_ref,
    filename = opts.filename,
    staged = opts.staged,
  })
end

function GitTree:is_initial()
  local parent_hash, _ = self:parent_hash()
  return not parent_hash or parent_hash == ''
end

function GitTree:is_merge()
  local commit, err = self:commit()
  if err then return false end

  if commit.parent_hashes and commit.parent_hashes:find(' ') then return true end

  return false
end

function GitTree:reset()
  self._commit_data = nil
  self._parent_tree = nil
  self._files = nil
  self._author = nil
  self._timestamp = nil
  self._message = nil
end

return GitTree
