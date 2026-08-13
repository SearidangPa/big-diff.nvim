local persistence = require('big-diff.nvim.review.persistence')
local M = {}
local uv = vim.uv or vim.loop
local MAX_REQUEST_BYTES = 64 * 1024

local function fail(message) error('(big-diff review) Invalid handoff: ' .. message, 0) end
local function normalize(path) return vim.fs.normalize(vim.fn.fnamemodify(path, ':p')) end

M.read = function(path)
  if type(path) ~= 'string' or path == '' then fail('BIG_DIFF_REVIEW_HANDOFF is not set') end
  path = normalize(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' or stat.size > MAX_REQUEST_BYTES then fail('request is missing or too large') end
  local fd = uv.fs_open(path, 'r', 384)
  if not fd then fail('request cannot be opened') end
  local text = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  local ok, request = pcall(vim.json.decode, text or '')
  if not ok or type(request) ~= 'table' then fail('request is not JSON') end
  if request.protocolVersion ~= 1 then fail('unsupported protocol version') end
  if type(request.requestId) ~= 'string' or request.requestId == '' then fail('missing request ID') end
  if type(request.token) ~= 'string' or not request.token:match('^[0-9a-f]+$') or #request.token ~= 64 then fail('invalid capability token') end

  local repo_real = uv.fs_realpath(request.repoRoot or '')
  local cwd_real = uv.fs_realpath(uv.cwd())
  if not repo_real or not cwd_real or repo_real ~= cwd_real then fail('repository root does not match Neovim cwd') end
  request.repoRoot = repo_real

  local handoff_dir = normalize(vim.fn.fnamemodify(path, ':h'))
  if normalize(request.resultPath or '') ~= normalize(vim.fs.joinpath(handoff_dir, 'result.json')) then fail('result path escapes handoff') end
  if type(request.pluginRoot) ~= 'string' or not uv.fs_realpath(request.pluginRoot) then fail('plugin root does not exist') end
  local expected_state = normalize(persistence.path_for_repo(repo_real))
  if normalize(request.reviewStatePath or '') ~= expected_state then fail('review state path does not match repository') end
  return request
end

M.write_result = function(request, result)
  result.protocolVersion = 1
  result.type = 'submit-review'
  result.requestId = request.requestId
  result.token = request.token
  result.repoRoot = request.repoRoot
  local ok, err = persistence.atomic_write(request.resultPath, result)
  if not ok then error('(big-diff review) Could not write result: ' .. tostring(err), 0) end
end

return M
