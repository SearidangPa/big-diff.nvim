local M = {}
local log = require('big-diff.nvim.utils_log')
local request_id = 0

local function parse_url(url)
  if type(url) ~= 'string' then return end
  local owner, repo, number, suffix = url:match('^https://github%.com/([%w_-]+)/([%w_.-]+)/pull/(%d+)(.*)$')
  if not owner or tonumber(number) == 0 then return end
  if suffix ~= '' and not suffix:match('^[/#?]') then return end
  return {
    repo = (owner .. '/' .. repo):lower(),
    url = 'https://github.com/' .. owner .. '/' .. repo .. '/pull/' .. number,
  }
end

local function valid_sha(value) return type(value) == 'string' and #value == 40 and value:match('^%x+$') ~= nil end

local function normalize_pr(raw)
  if type(raw) ~= 'table' then return end
  local pr = {
    number = raw.number,
    baseRefName = raw.baseRefName or raw.base_ref_name,
    baseRefOid = raw.baseRefOid or raw.base_ref_oid,
    headRefName = raw.headRefName or raw.head_ref_name,
    headRefOid = raw.headRefOid or raw.head_ref_oid,
  }
  if
    type(pr.number) == 'number'
    and pr.number > 0
    and type(pr.baseRefName) == 'string'
    and pr.baseRefName ~= ''
    and valid_sha(pr.baseRefOid)
    and type(pr.headRefName) == 'string'
    and pr.headRefName ~= ''
    and valid_sha(pr.headRefOid)
  then
    return pr
  end
end

local function find_remote(output, repo)
  for line in output:gmatch('[^\n]+') do
    local name, url = line:match('^(%S+)%s+(%S+)%s+%(fetch%)$')
    if name then
      local path = url:match('^https://github%.com/(.+)$')
        or url:match('^git@github%.com:(.+)$')
        or url:match('^ssh://git@github%.com/(.+)$')
      if path and path:gsub('/$', ''):gsub('%.git$', ''):lower() == repo then return name end
    end
  end
end

-- The split viewer reads the working tree, not a remote head snapshot. Require
-- the PR head locally so a URL can never silently display an unrelated branch.
-- Accepts either a PR URL string or a pre-fetched PR metadata table (from
-- `jiragh gh branch-pull --cached` or `gh pr view --json ...`), and returns an
-- ownership handle for async callers.
function M.open(input, opts)
  opts = opts or {}
  request_id = request_id + 1
  local id = request_id
  local raw_url = type(input) == 'table' and input.url or input
  local target = parse_url(raw_url)
  if not target then
    log.notify('Expected a GitHub PR URL: https://github.com/OWNER/REPO/pull/NUMBER', 'ERROR')
    return
  end
  local prefetched_pr = normalize_pr(input)
  local required_bins = prefetched_pr and { 'git' } or { 'git', 'gh' }
  for _, executable in ipairs(required_bins) do
    if vim.fn.executable(executable) ~= 1 then
      log.notify('Differ requires `' .. executable .. '` on PATH.', 'ERROR')
      return
    end
  end

  local ok, split_diff = pcall(require, 'diffhopper.split_diff')
  if not ok then
    pcall(vim.cmd.packadd, 'diffhopper.nvim')
    ok, split_diff = pcall(require, 'diffhopper.split_diff')
  end
  if not ok then
    log.notify('`:Differ` requires diffhopper.nvim.', 'ERROR')
    return
  end

  local initial_session = split_diff.get_session_id()
  local initial_view_open = split_diff.is_open()
  local view_session
  local active_pr = prefetched_pr
  local aborted = false
  local handle = {}
  function handle.has_view()
    return view_session ~= nil and split_diff.is_open() and split_diff.get_session_id() == view_session
  end
  function handle.is_current()
    if aborted or id ~= request_id then return false end
    if view_session ~= nil then return handle.has_view() end
    return split_diff.get_session_id() == initial_session
  end
  function handle.matches(other)
    if not handle.is_current() then return false end
    local other_url = type(other) == 'table' and other.url or other
    local other_target = parse_url(other_url)
    if not other_target or other_target.url ~= target.url then return false end
    local other_pr = normalize_pr(other)
    if active_pr and other_pr then
      return active_pr.baseRefOid == other_pr.baseRefOid
        and active_pr.headRefOid == other_pr.headRefOid
        and active_pr.baseRefName == other_pr.baseRefName
        and active_pr.headRefName == other_pr.headRefName
    end
    return true
  end
  function handle.cancel(close_view)
    if not handle.is_current() then return end
    aborted = true
    request_id = request_id + 1
    if close_view and handle.has_view() then split_diff.close() end
  end

  local function fail(message)
    aborted = true
    if opts.provisional and not handle.has_view() then
      request_id = request_id + 1
      return
    end
    log.notify(message, 'ERROR')
  end

  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local original_cwd = vim.fn.getcwd()
  local path = vim.api.nvim_buf_get_name(buf)
  local cwd = vim.bo[buf].buftype == '' and path ~= '' and vim.fn.fnamemodify(vim.fn.resolve(path), ':h')
    or original_cwd

  local function is_current()
    if not handle.is_current() then return false end
    -- A cached view may still be rendering/navigating when a corrected URL
    -- starts loading. Its own file changes are not an unrelated buffer switch.
    local in_initial_view = initial_view_open
      and split_diff.is_open()
      and split_diff.get_session_id() == initial_session
      and type(vim.b.diffhopper_diff_path) == 'string'
    if
      not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_get_current_win() ~= win
      or (vim.api.nvim_win_get_buf(win) ~= buf and not in_initial_view)
      or vim.fn.getcwd() ~= original_cwd
    then
      aborted = true
      request_id = request_id + 1
      log.notify('Differ cancelled because the window, buffer, or directory changed; run it again.', 'WARN')
      return false
    end
    return true
  end

  -- Run network and Git work asynchronously. A nil failure message lets the
  -- caller handle a nonzero status (used to probe for the base commit).
  local function run(command, failure, callback)
    local started, err = pcall(
      vim.system,
      command,
      { cwd = cwd, text = true, timeout = 60000 },
      vim.schedule_wrap(function(result)
        if not is_current() then return end
        if result.code ~= 0 and failure then
          local detail = vim.trim(result.stderr or '')
          if detail == '' then detail = 'exit code ' .. tostring(result.code) end
          fail(failure .. ': ' .. detail)
          return
        end
        callback(vim.trim(result.stdout or ''), result)
      end)
    )
    if not started then fail('Could not run ' .. command[1] .. ': ' .. tostring(err)) end
  end

  local function git(args, failure, callback) run(vim.list_extend({ 'git' }, args), failure, callback) end

  local function check_head(pr, callback)
    git({ 'rev-parse', 'HEAD' }, 'Could not resolve HEAD', function(head)
      if head ~= pr.headRefOid then
        fail('Check out the PR head first: gh pr checkout ' .. target.url .. ' (no checkout or reset was performed).')
        return
      end
      callback()
    end)
  end

  local function show_diff(pr)
    git(
      { 'merge-base', pr.baseRefOid, pr.headRefOid },
      'Could not find the PR merge-base (fetch more history if this is a shallow clone)',
      function(base)
        if not valid_sha(base) then
          fail('Git returned an invalid merge-base.')
          return
        end
        -- A checkout may have happened while the fetch was running.
        check_head(pr, function()
          log.notify(
            'PR #'
              .. pr.number
              .. ': '
              .. pr.headRefName
              .. ' → '
              .. pr.baseRefName
              .. ' (merge-base '
              .. base:sub(1, 12)
              .. '; includes local changes)',
            'INFO'
          )
          split_diff.open(base)
          view_session = split_diff.get_session_id()
        end)
      end
    )
  end

  local function ensure_base(pr)
    git({ 'cat-file', '-e', pr.baseRefOid .. '^{commit}' }, nil, function(_, result)
      if result.code == 0 then return show_diff(pr) end
      git({ 'remote', '-v' }, 'Could not list Git remotes', function(remotes)
        local remote = find_remote(remotes, target.repo)
        if not remote then
          fail(
            'The PR base commit is missing. Add a Git remote for '
              .. target.repo
              .. ' (HTTPS or git@github.com), fetch it, and retry.'
          )
          return
        end
        -- Fetch the exact API snapshot, not a potentially stale local branch or
        -- a branch that moved after the API call. Do not update local refs.
        git(
          { 'fetch', '--no-tags', '--no-write-fetch-head', '--', remote, pr.baseRefOid },
          'Could not fetch the PR base commit',
          function() show_diff(pr) end
        )
      end)
    end)
  end

  git({ 'rev-parse', '--show-toplevel' }, 'Open a file in the PR repository first', function(root)
    cwd = root
    if prefetched_pr then
      check_head(prefetched_pr, function() ensure_base(prefetched_pr) end)
      return
    end
    run(
      { 'gh', 'pr', 'view', target.url, '--json', 'number,baseRefName,baseRefOid,headRefName,headRefOid' },
      'Could not read the PR (check gh auth login and repository access)',
      function(output)
        local decoded, raw = pcall(vim.json.decode, output)
        local pr = decoded and normalize_pr(raw) or nil
        if not pr then
          fail('GitHub returned incomplete PR branch/commit metadata.')
          return
        end
        active_pr = pr
        check_head(pr, function() ensure_base(pr) end)
      end
    )
  end)
  return handle
end

return M
