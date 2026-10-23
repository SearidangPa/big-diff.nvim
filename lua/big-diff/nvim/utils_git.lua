local M = {}

---@type table<string, { branch?: string, inflight?: fun(branch: string)[] }>
local default_base_branch_cache = {}

---@param path string
---@return string
local function normalize_path(path) return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ':p'))) end

---@param path string
---@return boolean
local function is_absolute_path(path)
  if not path or path == '' then return false end

  return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil or path:match('^\\\\') ~= nil
end

---@param path string
---@return string?
local function find_git_root_from_path(path)
  local dir = vim.fn.fnamemodify(path, ':p:h')

  while dir ~= '/' and dir ~= '' do
    local git_path = dir .. '/.git'
    if vim.fn.isdirectory(git_path) == 1 or vim.fn.filereadable(git_path) == 1 then return dir end
    dir = vim.fn.fnamemodify(dir, ':h')
  end

  return nil
end

---@param buffer_number? integer
---@return string?
function M.find_git_root(buffer_number)
  buffer_number = buffer_number or 0
  local bufname = vim.api.nvim_buf_get_name(buffer_number)

  local path
  if bufname == '' then
    path = vim.fn.getcwd()
  else
    -- IMPORTANT: resolve symlinks (stow)
    path = vim.fn.resolve(bufname)
  end

  return find_git_root_from_path(path)
end

---@param path string
---@return string?
function M.find_git_root_for_path(path)
  if not path or path == '' then return nil end

  return find_git_root_from_path(vim.fn.resolve(path))
end

---@param filepath string
---@param git_root string
---@return string
function M.to_repo_relative_path(filepath, git_root)
  local normalized_root = normalize_path(git_root)
  local normalized_file = normalize_path(filepath)
  local root_prefix = normalized_root .. '/'

  if normalized_file == normalized_root then return '.' end

  if normalized_file:sub(1, #root_prefix) == root_prefix then return normalized_file:sub(#root_prefix + 1) end

  return vim.fs.normalize(filepath)
end

---@param callback fun(branch: string)
---@param options? { git_root?: string, fallback?: string, no_cache?: boolean }
function M.get_default_base_branch_async(callback, options)
  options = options or {}
  local fallback = options.fallback or 'main'

  local git_root = options.git_root or M.find_git_root()
  if not git_root then
    callback(fallback)
    return
  end

  local cached = default_base_branch_cache[git_root]
  if not options.no_cache and cached and cached.branch then
    callback(cached.branch)
    return
  end

  cached = cached or {}
  default_base_branch_cache[git_root] = cached

  -- Coalesce concurrent callers: only run one job per git_root.
  if cached.inflight then
    table.insert(cached.inflight, callback)
    return
  end

  cached.inflight = { callback }

  local function run_callbacks(branch)
    local callbacks = cached.inflight or {}
    cached.inflight = nil
    for _, cb in ipairs(callbacks) do
      vim.schedule(function() cb(branch) end)
    end
  end

  local function finish(branch)
    cached.branch = branch
    run_callbacks(branch)
  end

  local function resolve_origin_head(callback_fn)
    vim.system({
      'git',
      '-C',
      git_root,
      'symbolic-ref',
      'refs/remotes/origin/HEAD',
    }, { text = true }, function(obj)
      if obj.code ~= 0 then
        callback_fn(nil)
        return
      end

      local ref = vim.trim(obj.stdout or '')
      local branch = ref:match('^refs/remotes/origin/(.+)$') or ''
      if branch == '' then
        callback_fn(nil)
        return
      end

      callback_fn('origin/' .. branch)
    end)
  end

  local function fallback_to_upstream_or_current_branch()
    vim.system({
      'git',
      '-C',
      git_root,
      'rev-parse',
      '--abbrev-ref',
      '--symbolic-full-name',
      '@{upstream}',
    }, { text = true }, function(obj)
      if obj.code == 0 then
        local upstream = vim.trim(obj.stdout or '')
        if upstream ~= '' then
          finish(upstream)
          return
        end
      end

      vim.system({
        'git',
        '-C',
        git_root,
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      }, { text = true }, function(branch_obj)
        if branch_obj.code ~= 0 then
          run_callbacks(fallback)
          return
        end

        local current_branch = vim.trim(branch_obj.stdout or '')
        if current_branch == '' or current_branch == 'HEAD' then
          run_callbacks(fallback)
          return
        end

        vim.system({
          'git',
          '-C',
          git_root,
          'show-ref',
          '--verify',
          '--quiet',
          'refs/remotes/origin/' .. current_branch,
        }, { text = true }, function(ref_obj)
          if ref_obj.code == 0 then
            finish('origin/' .. current_branch)
            return
          end

          run_callbacks(fallback)
        end)
      end)
    end)
  end

  resolve_origin_head(function(origin_head)
    if origin_head and origin_head ~= '' then
      finish(origin_head)
      return
    end

    fallback_to_upstream_or_current_branch()
  end)
end

---@class BigDiffHunkItem : BigDiffHunk
---@field file string repo relative path
---@field block BigDiffBlock

local function uv() return vim.uv or vim.loop end

---Reads a file without touching vimscript, so it is safe in a libuv callback.
---@param path string
---@param max_bytes number
---@return string?, boolean too_large
local function read_file(path, max_bytes)
  local fd = uv().fs_open(path, 'r', 438)
  if not fd then return nil, false end

  local stat = uv().fs_fstat(fd)
  if not stat then
    uv().fs_close(fd)
    return nil, false
  end

  if stat.size > max_bytes then
    uv().fs_close(fd)
    return nil, true
  end

  local content = uv().fs_read(fd, stat.size, 0)
  uv().fs_close(fd)
  return content, false
end

---Builds a synthetic `new file` diff for an untracked path.
---@param git_root string
---@param file string
---@param max_bytes number
---@return BigDiffBlock?
local function untracked_block(git_root, file, max_bytes)
  local diff_parse = require('big-diff.nvim.patch')
  local content, too_large = read_file(git_root .. '/' .. file, max_bytes)

  local lines = {
    ('diff --git a/%s b/%s'):format(file, file),
    'new file mode 100644',
    '--- /dev/null',
    ('+++ b/%s'):format(file),
  }

  if content and not content:find('%z') then
    local body = vim.split(content, '\n', { plain = true })
    local trailing_newline = body[#body] == ''
    if trailing_newline then table.remove(body) end

    if #body > 0 then
      lines[#lines + 1] = ('@@ -0,0 +1,%d @@'):format(#body)
      for _, text in ipairs(body) do
        lines[#lines + 1] = '+' .. text
      end
      if not trailing_newline then lines[#lines + 1] = '\\ No newline at end of file' end
    end
  elseif content then
    lines[#lines + 1] = ('Binary files /dev/null and b/%s differ'):format(file)
  elseif too_large then
    lines[#lines + 1] = ('Binary files /dev/null and b/%s differ'):format(file)
  end

  local block = diff_parse.parse(lines).blocks[1]
  if block then block.untracked = true end
  return block
end

---@param git_root? string
---@param extra string[]
---@return string[]
local function git_cmd(git_root, extra)
  local cmd = { 'git', '--no-pager', '-c', 'core.quotepath=false' }
  if git_root and git_root ~= '' then
    cmd[#cmd + 1] = '-C'
    cmd[#cmd + 1] = git_root
  end
  return vim.list_extend(cmd, extra)
end

---@param this_file? string
---@param git_root? string
---@return string?
local function pathspec(this_file, git_root)
  if not this_file or this_file == '' then return nil end
  if git_root and git_root ~= '' and is_absolute_path(this_file) then
    return M.to_repo_relative_path(this_file, git_root)
  end
  return this_file
end

---@class BigDiffDiffOpts
---@field git_root? string
---@field buffer_number? integer
---@field ignore_whitespace? boolean
---@field context_lines? number unified context, defaults to 0
---@field merge_base? boolean diff against the merge base of `base` and HEAD
---@field staged? boolean true: index only, false: worktree only, nil: both
---@field include_untracked? boolean
---@field detect_staged? boolean flag blocks whose file has staged changes

---Runs `git diff` and returns every hunk it produced.
---
---`hunks[i].line`/`.count` are the raw `@@` values on the new side, while
---`.change_line`/`.change_count` skip leading context. Each hunk keeps its
---text in `.diff` and its file metadata in `.block`.
---@param base? string
---@param this_file? string
---@param callback fun(hunks: BigDiffHunkItem[], blocks: BigDiffBlock[])
---@param options? BigDiffDiffOpts
function M.get_diff_hunks(base, this_file, callback, options)
  base = base or 'HEAD'

  options = options or {}
  local git_root = options.git_root or M.find_git_root(options.buffer_number)
  local diff_parse = require('big-diff.nvim.patch')
  local file = pathspec(this_file, git_root)

  ---@param use_merge_base boolean
  ---@return string[]
  local function build_cmd(use_merge_base)
    local args = {
      'diff',
      '--no-color',
      '--no-ext-diff',
      ('--unified=%d'):format(options.context_lines or 0),
    }
    if options.ignore_whitespace then args[#args + 1] = '--ignore-all-space' end
    if options.staged then args[#args + 1] = '--cached' end
    if base and base ~= '' and options.staged ~= false then
      if use_merge_base then args[#args + 1] = '--merge-base' end
      args[#args + 1] = base
    end
    if file then
      args[#args + 1] = '--'
      args[#args + 1] = file
    end
    return git_cmd(git_root, args)
  end

  ---Collects untracked paths and the set of files with staged changes, so
  ---blocks can be flagged without a second diff pass.
  ---@param finish fun(untracked: string[], staged: table<string, boolean>)
  local function collect_extras(finish)
    local untracked = {}
    local staged = {}
    local pending = 0
    local function done()
      pending = pending - 1
      if pending == 0 then finish(untracked, staged) end
    end

    local jobs = {}

    if options.include_untracked and not options.staged then
      local args = { 'ls-files', '--others', '--exclude-standard', '-z' }
      if file then
        args[#args + 1] = '--'
        args[#args + 1] = file
      end
      jobs[#jobs + 1] = {
        cmd = git_cmd(git_root, args),
        handler = function(obj)
          for _, path in
            ipairs(vim.split(obj.stdout or '', '\0', {
              plain = true,
              trimempty = true,
            }))
          do
            untracked[#untracked + 1] = path
          end
        end,
      }
    end

    if options.staged == nil and options.detect_staged then
      local args = { 'diff', '--cached', '--name-only', '-z' }
      if file then
        args[#args + 1] = '--'
        args[#args + 1] = file
      end
      jobs[#jobs + 1] = {
        cmd = git_cmd(git_root, args),
        handler = function(obj)
          for _, path in
            ipairs(vim.split(obj.stdout or '', '\0', {
              plain = true,
              trimempty = true,
            }))
          do
            staged[path] = true
          end
        end,
      }
    end

    if #jobs == 0 then
      finish(untracked, staged)
      return
    end

    pending = #jobs
    for _, job in ipairs(jobs) do
      vim.system(job.cmd, { text = true }, function(obj)
        if obj.code == 0 then job.handler(obj) end
        done()
      end)
    end
  end

  ---@param output string
  local function finish(output)
    local blocks = diff_parse.parse(vim.split(output, '\n', { plain = true })).blocks

    collect_extras(function(untracked, staged)
      local max_bytes = require('big-diff.nvim.config').get_picker_config().git.untracked_max_bytes
      for _, path in ipairs(untracked) do
        local block = untracked_block(git_root or '.', path, max_bytes)
        if block then blocks[#blocks + 1] = block end
      end

      for _, block in ipairs(blocks) do
        if options.staged then
          block.staged = true
        elseif staged[block.file] then
          block.staged = true
        end
      end

      ---@type BigDiffHunkItem[]
      local hunks = {}
      for _, block in ipairs(blocks) do
        for _, hunk in ipairs(block.hunks) do
          local item = hunk --[[@as BigDiffHunkItem]]
          item.file = block.file
          item.block = block
          hunks[#hunks + 1] = item
        end
      end

      vim.schedule(function() callback(hunks, blocks) end)
    end)
  end

  local use_merge_base = options.merge_base == true and base ~= nil and base ~= '' and options.staged ~= false
  vim.system(build_cmd(use_merge_base), { text = true }, function(obj)
    if obj.code == 0 or not use_merge_base then
      finish(obj.stdout or '')
      return
    end

    -- `--merge-base` fails for refs with no common ancestor (and on git
    -- older than 2.30); fall back to a plain two-dot diff.
    vim.system(build_cmd(false), { text = true }, function(plain) finish(plain.stdout or '') end)
  end)
end

return M
