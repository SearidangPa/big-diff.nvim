local M = {}
local uv = vim.uv or vim.loop

local function notify(message, level)
  vim.notify('(big-diff review) ' .. message, level or vim.log.levels.ERROR)
end

local function ensure_parent(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p', '0700')
end

M.path_for_repo = function(repo_root)
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'big-diff', 'reviews', vim.fn.sha256(repo_root) .. '.json')
end

M.atomic_write = function(path, value)
  ensure_parent(path)
  local temporary = string.format('%s.tmp-%d-%d', path, vim.fn.getpid(), math.random(100000, 999999))
  local encoded = vim.json.encode(value)
  local fd, open_error = uv.fs_open(temporary, 'wx', 384)
  if not fd then return nil, open_error end
  local ok, write_error = uv.fs_write(fd, encoded .. '\n', -1)
  if ok then uv.fs_fsync(fd) end
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(temporary)
    return nil, write_error
  end
  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then uv.fs_unlink(temporary); return nil, rename_error end
  return true
end

M.load = function(repo_root, explicit_path)
  local path = explicit_path or M.path_for_repo(repo_root)
  local fd = uv.fs_open(path, 'r', 384)
  if not fd then return { schema_version = 1, repo_root = repo_root, reviews = {} }, path end
  local stat = uv.fs_fstat(fd)
  local text = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  local ok, state = pcall(vim.json.decode, text or '')
  if not ok or type(state) ~= 'table' or type(state.reviews) ~= 'table' or state.repo_root ~= repo_root then
    local recovery = path .. '.corrupt-' .. os.date('!%Y%m%dT%H%M%SZ')
    local renamed = uv.fs_rename(path, recovery)
    notify('Review state is corrupt; preserved at ' .. (renamed and recovery or path))
    return { schema_version = 1, repo_root = repo_root, reviews = {} }, path
  end
  return state, path
end

M.save = function(state, path)
  state.schema_version = 1
  state.updated_at = os.time() * 1000
  local ok, err = M.atomic_write(path, state)
  if not ok then notify('Could not save reviews: ' .. tostring(err)); return false end
  return true
end

return M
