-- Run from the repository root: nvim --headless -u NONE -l tests/differ.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.g.minidiff_disable = true

local system, notify, executable = vim.system, vim.notify, vim.fn.executable
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, 'p')
local upstream = sandbox .. '/upstream'
local url = 'https://github.com/PreVeil/drive/pull/1944'
local opened, messages, calls, scenario, checkout
local count = 0
local view_session, view_open = 0, false

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end

local function command(args, cwd)
  local result = system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end

local function git(args, cwd) return command(vim.list_extend({ 'git' }, args), cwd or upstream) end

local function file(path, contents) vim.fn.writefile({ contents }, path) end

local function commit(name)
  git({ 'add', '.' })
  git({ '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', name })
  return git({ 'rev-parse', 'HEAD' })
end

package.preload['diffhopper.split_diff'] = function()
  return {
    open = function(base)
      view_session, view_open = view_session + 1, true
      opened[#opened + 1] = base
    end,
    close = function()
      view_session, view_open = view_session + 1, false
    end,
    get_session_id = function() return view_session end,
    is_open = function() return view_open end,
  }
end
require('big-diff.nvim').setup()
local differ = require('big-diff.nvim.differ')

vim.notify = function(message, level) messages[#messages + 1] = { message = message, level = level } end
vim.fn.executable = function(name)
  if scenario and scenario.missing == name then return 0 end
  if name == 'gh' or name == 'jiragh' then return 1 end -- CLI responses are stubbed below.
  return executable(name)
end

local function respond(callback, result)
  vim.schedule(function() callback(vim.tbl_extend('force', { code = 0, stdout = '', stderr = '' }, result)) end)
  return {}
end

local pr
vim.system = function(args, opts, callback)
  calls[#calls + 1] = { args = vim.deepcopy(args), cwd = opts.cwd }
  if scenario.race and (args[1] == 'jiragh' or (args[1] == 'gh' and args[4] == '--json')) then
    scenario[args[1] .. '_reply'] = callback
    return {}
  end
  if args[1] == 'gh' then
    if scenario.change_buffer then vim.cmd.enew() end
    if scenario.delay_gh then
      scenario.delayed = callback
      return {}
    end
    return respond(callback, scenario.gh or { stdout = vim.json.encode(pr) })
  end
  if args[2] == 'remote' then
    return respond(callback, {
      stdout = scenario.remotes
        or 'origin\tgit@github.com:PreVeil/drive.git (fetch)\norigin\tgit@github.com:PreVeil/drive.git (push)\n',
    })
  end
  if args[2] == scenario.fail_git then
    return respond(callback, { code = 1, stderr = 'simulated ' .. args[2] .. ' failure' })
  end
  if args[2] == 'fetch' and scenario.change_head then
    return system(
      args,
      opts,
      vim.schedule_wrap(function(result)
        git({ 'checkout', '--quiet', '--detach', pr.baseRefOid }, checkout)
        callback(result)
      end)
    )
  end
  return system(args, opts, callback)
end

local function prepare(options)
  scenario = options or {}
  opened, messages, calls = {}, {}, {}
  view_session, view_open = view_session + 1, false
  checkout = sandbox .. '/checkout-' .. tostring(count)
  command({ 'git', 'clone', '--quiet', '--no-local', '--single-branch', '--branch', 'feature', upstream, checkout })
  if scenario.have_base then git({ 'fetch', '--quiet', 'origin', pr.baseRefOid }, checkout) end
  if scenario.upstream then git({ 'remote', 'rename', 'origin', 'upstream' }, checkout) end
  vim.cmd.cd(vim.fn.fnameescape(checkout))
  vim.cmd.edit(vim.fn.fnameescape(checkout .. '/file.txt'))
end

local function done() return #opened > 0 or (#messages > 0 and messages[#messages].level >= vim.log.levels.WARN) end

local function invoke(argument)
  differ.open(argument or url)
  assert(vim.wait(10000, done, 5), 'Timed out: ' .. vim.inspect(calls))
end

local function error_contains(needle)
  eq(0, #opened)
  local last = messages[#messages]
  assert(
    last and last.level >= vim.log.levels.WARN and last.message:find(needle, 1, true),
    'Missing error ' .. needle .. ': ' .. vim.inspect(messages)
  )
end

local function find_call(subcommand)
  for _, call in ipairs(calls) do
    if call.args[1] == 'git' and call.args[2] == subcommand then return call end
  end
end

local function test(name, fn)
  count = count + 1
  fn()
  print('ok ' .. count .. ' - ' .. name)
end

local ok, err = xpcall(function()
  vim.fn.mkdir(upstream, 'p')
  git({ 'init', '--quiet', '--initial-branch=main' })
  file(upstream .. '/file.txt', 'original')
  commit('main')
  git({ 'checkout', '--quiet', '-b', 'release/6.3.3' })
  file(upstream .. '/release.txt', 'release-only change')
  local merge_base = commit('release base')
  git({ 'checkout', '--quiet', '-b', 'feature' })
  file(upstream .. '/file.txt', 'PR change')
  local head = commit('PR head')
  git({ 'checkout', '--quiet', 'release/6.3.3' })
  file(upstream .. '/base-only.txt', 'base advanced after the PR branched')
  local base = commit('base advanced')
  pr = { number = 1944, baseRefName = 'release/6.3.3', baseRefOid = base, headRefName = 'feature', headRefOid = head }

  test('registers Differ without changing Diff commit/count behavior', function()
    prepare()
    local commands = vim.api.nvim_get_commands({})
    eq('1', commands.Differ.nargs)
    vim.cmd('Diff commit')
    vim.cmd('Diff 3')
    eq({ 'HEAD~1', 'HEAD~3' }, opened)
  end)

  test('fetches missing non-main base and opens merge-base, not base tip or main', function()
    prepare()
    local before = git({ 'show-ref' }, checkout)
    vim.cmd('Differ ' .. url)
    assert(vim.wait(10000, done, 5), 'Timed out')
    eq({ merge_base }, opened)
    eq({ 'git', 'fetch', '--no-tags', '--no-write-fetch-head', '--', 'origin', base }, find_call('fetch').args)
    eq(before, git({ 'show-ref' }, checkout))
    eq(head, git({ 'rev-parse', 'HEAD' }, checkout))
    eq('', git({ 'status', '--porcelain' }, checkout))
    assert(messages[#messages].message:find('release/6.3.3', 1, true))
    eq('file.txt', git({ 'diff', '--name-only', opened[1] }, checkout))
  end)

  test('uses an already available base without fetching; accepts files URL and fragment', function()
    prepare({ have_base = true })
    invoke(url .. '/files#diff-123')
    eq({ merge_base }, opened)
    eq(nil, find_call('fetch'))
    eq(nil, find_call('remote'))
    eq(url, calls[2].args[4])
  end)

  test('uses upstream HTTPS remote for fork PRs', function()
    prepare({
      upstream = true,
      remotes = 'origin\tgit@github.com:someone/drive.git (fetch)\n'
        .. 'upstream\thttps://github.com/PreVeil/drive.git (fetch)\n',
    })
    invoke()
    eq({ merge_base }, opened)
    eq('upstream', find_call('fetch').args[6])
  end)

  test('supports ssh:// GitHub remotes', function()
    prepare({ remotes = 'origin\tssh://git@github.com/PreVeil/drive.git (fetch)\n' })
    invoke()
    eq({ merge_base }, opened)
  end)

  test('rejects a different checked-out HEAD without fetching or checking out', function()
    prepare()
    git({ 'checkout', '--quiet', '--detach', merge_base }, checkout)
    invoke()
    error_contains('gh pr checkout ' .. url)
    eq(nil, find_call('fetch'))
    eq(merge_base, git({ 'rev-parse', 'HEAD' }, checkout))
  end)

  test('detects a checkout that changed during the fetch', function()
    prepare({ change_head = true })
    invoke()
    error_contains('Check out the PR head first')
  end)

  test('preserves local changes and warns they are included', function()
    prepare({ have_base = true })
    file(checkout .. '/file.txt', 'local edit')
    file(checkout .. '/untracked.txt', 'local untracked file')
    local before = git({ 'status', '--porcelain' }, checkout)
    invoke()
    eq({ merge_base }, opened)
    eq(before, git({ 'status', '--porcelain' }, checkout))
    assert(messages[#messages].message:find('includes local changes', 1, true))
  end)

  test('rejects malformed and non-GitHub URLs before invoking tools', function()
    prepare()
    for _, invalid in ipairs({
      '',
      '1944',
      'https://example.com/PreVeil/drive/pull/1944',
      'https://github.com/PreVeil/drive/pull/1944oops',
      'https://github.com/PreVeil/drive/pull/0',
    }) do
      invoke(invalid)
      error_contains('Expected a GitHub PR URL')
      eq(0, #calls)
    end
  end)

  test('reports missing gh', function()
    prepare({ missing = 'gh' })
    invoke()
    error_contains('requires `gh`')
    eq(0, #calls)
  end)

  test('reports missing git', function()
    prepare({ missing = 'git' })
    invoke()
    error_contains('requires `git`')
    eq(0, #calls)
  end)

  test('reports authentication/API failures', function()
    prepare({ gh = { code = 1, stderr = 'authentication required' } })
    invoke()
    error_contains('authentication required')
    eq(nil, find_call('fetch'))
  end)

  test('reports invalid JSON', function()
    prepare({ gh = { stdout = 'not json' } })
    invoke()
    error_contains('incomplete PR branch/commit metadata')
  end)

  test('rejects invalid commit metadata', function()
    prepare({ gh = { stdout = vim.json.encode(vim.tbl_extend('force', pr, { baseRefOid = '--bad-ref' })) } })
    invoke()
    error_contains('incomplete PR branch/commit metadata')
    eq(nil, find_call('fetch'))
  end)

  test('reports missing repository', function()
    prepare()
    file(sandbox .. '/outside.txt', 'outside any Git repository')
    vim.cmd.edit(vim.fn.fnameescape(sandbox .. '/outside.txt'))
    invoke()
    error_contains('Open a file in the PR repository first')
    eq(1, #calls)
  end)

  test('does not fetch from unrelated remotes or push-only matches', function()
    prepare({
      remotes = 'origin\tgit@github.com:someone/drive.git (fetch)\n'
        .. 'origin\tgit@github.com:PreVeil/drive.git (push)\n',
    })
    invoke()
    error_contains('Add a Git remote for preveil/drive')
    eq(nil, find_call('fetch'))
  end)

  test('reports fetch errors without opening a diff', function()
    prepare({ fail_git = 'fetch' })
    invoke()
    error_contains('Could not fetch the PR base commit')
  end)

  test('reports missing merge-base without falling back to main', function()
    prepare({ have_base = true, fail_git = 'merge-base' })
    invoke()
    error_contains('fetch more history if this is a shallow clone')
  end)

  test('does not open a diff in a buffer selected while gh was running', function()
    prepare({ change_buffer = true })
    invoke()
    error_contains('Differ cancelled')
  end)

  test('ignores stale responses after a newer invocation', function()
    prepare({ have_base = true, delay_gh = true })
    differ.open(url)
    assert(vim.wait(10000, function() return scenario.delayed ~= nil end, 5))
    local delayed = scenario.delayed
    scenario.delay_gh = false
    invoke()
    eq({ merge_base }, opened)
    delayed({ code = 0, stdout = vim.json.encode(pr), stderr = '' })
    vim.wait(50, function() return false end, 5)
    eq({ merge_base }, opened)
  end)

  test('cancels an owned pending request without opening its stale response', function()
    prepare({ have_base = true, delay_gh = true })
    local handle = differ.open(url)
    assert(vim.wait(10000, function() return scenario.delayed ~= nil end, 5))
    eq(true, handle.is_current())
    eq(false, handle.has_view())
    handle.cancel(true)
    scenario.delayed({ code = 0, stdout = vim.json.encode(pr), stderr = '' })
    vim.wait(50, function() return false end, 5)
    eq({}, opened)
    eq(false, handle.is_current())
  end)

  test('cancels only the view opened by this request', function()
    prepare({ have_base = true })
    local handle = differ.open(url)
    assert(vim.wait(10000, done, 5))
    eq(true, handle.has_view())
    handle.cancel(true)
    eq(false, require('diffhopper.split_diff').is_open())
    eq(false, handle.is_current())
  end)

  test('closed and replaced views invalidate handles even at the same base', function()
    prepare({ have_base = true })
    local handle = differ.open(url)
    assert(vim.wait(10000, done, 5))
    local split = require('diffhopper.split_diff')
    split.close()
    eq(false, handle.is_current())
    split.open(merge_base)
    eq(false, handle.is_current())
    handle.cancel(true)
    eq(true, split.is_open())
  end)

  test('opening another diff during PR lookup invalidates the pending request', function()
    prepare({ have_base = true, delay_gh = true })
    local handle = differ.open(url)
    assert(vim.wait(10000, function() return scenario.delayed ~= nil end, 5))
    require('diffhopper.split_diff').open('HEAD')
    scenario.delayed({ code = 0, stdout = vim.json.encode(pr), stderr = '' })
    vim.wait(50, function() return false end, 5)
    eq({ 'HEAD' }, opened)
    eq(false, handle.is_current())
  end)

  test('a corrected request tolerates file navigation in the prior view', function()
    prepare({ have_base = true, delay_gh = true })
    require('diffhopper.split_diff').open('HEAD')
    local handle = differ.open(url)
    assert(vim.wait(10000, function() return scenario.delayed ~= nil end, 5))
    vim.cmd.enew()
    vim.b.diffhopper_diff_path = 'file.txt'
    scenario.delayed({ code = 0, stdout = vim.json.encode(pr), stderr = '' })
    assert(vim.wait(10000, function() return #opened == 2 end, 5))
    eq({ 'HEAD', merge_base }, opened)
    eq(true, handle.has_view())
  end)

  if vim.env.DIFFHOPPER_RTP then
    test('renders and closes the real diffhopper file tree and big-diff overlay', function()
      prepare({ have_base = true })
      local buf = vim.api.nvim_get_current_buf()
      for _, other in ipairs(vim.api.nvim_list_bufs()) do
        if other ~= buf then vim.api.nvim_buf_delete(other, { force = true }) end
      end
      vim.opt.runtimepath:append(vim.env.DIFFHOPPER_RTP)
      package.loaded['diffhopper.split_diff'] = nil
      package.preload['diffhopper.split_diff'] = nil
      local split = require('diffhopper.split_diff')
      local core = require('big-diff.nvim')
      vim.g.minidiff_disable = false
      vim.g.minidiff_git_base_ref = 'HEAD'
      core.setup({
        source = core.gen_source.git({ ref = function() return vim.g.minidiff_git_base_ref end }),
      })
      assert(
        vim.wait(10000, function()
          local data = core.get_buf_data(buf)
          return data and data.ref_text == 'PR change\n'
        end, 5),
        'Initial reference text was not loaded'
      )
      vim.cmd('Differ ' .. url)
      assert(
        vim.wait(10000, function()
          local data = core.get_buf_data(buf)
          return split.is_file_tree_visible() and data and data.ref_text == 'original\n' and #data.hunks == 1
        end, 5),
        'PR overlay did not render: ' .. vim.inspect(messages)
      )
      eq(merge_base, vim.g.minidiff_git_base_ref)
      eq(true, core.get_buf_data(buf).overlay)
      eq(2, #vim.api.nvim_list_wins())
      split.close()
      eq('HEAD', vim.g.minidiff_git_base_ref)
      eq(false, split.is_open())
      eq(false, core.get_buf_data(buf).overlay)
      eq(1, #vim.api.nvim_list_wins())
      assert(
        vim.wait(10000, function()
          local data = core.get_buf_data(buf)
          return data and data.ref_text == 'PR change\n' and #data.hunks == 0
        end, 5),
        'Closing the view did not restore the previous reference'
      )
      core.disable(buf)
    end)

    test('closing a view discards a late file/hunk callback without changing buffers', function()
      prepare({ have_base = true })
      vim.cmd.edit(vim.fn.fnameescape(checkout .. '/release.txt'))
      local original_buf = vim.api.nvim_get_current_buf()
      local split = require('diffhopper.split_diff')
      local git_util = require('diffhopper.util_git')
      local get_diff_hunks = git_util.get_diff_hunks
      local callbacks = {}
      git_util.get_diff_hunks = function(_, _, callback) callbacks[#callbacks + 1] = callback end
      split.open(merge_base)
      local on_open_called = false
      require('diffhopper.split_diff.git').open_file_in_main_win(
        merge_base,
        checkout,
        { path = 'file.txt', status = 'M' },
        vim.api.nvim_get_current_win(),
        function() on_open_called = true end
      )
      eq(1, #callbacks)
      callbacks[1]({ { line = 1, count = 1 } })
      eq(2, #callbacks)
      split.close()
      callbacks[2]({ { line = 1, count = 1 } })
      eq(original_buf, vim.api.nvim_get_current_buf())
      eq(false, on_open_called)
      git_util.get_diff_hunks = get_diff_hunks
    end)

    if vim.env.NVIM_CONFIG_RTP then
      vim.opt.runtimepath:append(vim.env.NVIM_CONFIG_RTP)
      local config = require('pack.big_diff')
      local split = require('diffhopper.split_diff')
      local core = require('big-diff.nvim')
      for _, outcome in ipairs({ 'same', 'different', 'none', 'closed' }) do
        test('real cache/gh race after rendering: ' .. outcome, function()
          prepare({ have_base = true, race = true })
          -- The preview will switch from this unchanged file to file.txt.
          vim.cmd.edit(vim.fn.fnameescape(checkout .. '/release.txt'))
          config.open_branch_pr()
          assert(scenario.jiragh_reply and scenario.gh_reply, 'Lookups did not start concurrently')
          scenario.jiragh_reply({
            code = 0,
            stderr = '',
            stdout = vim.json.encode({
              ok = true,
              repo = 'PreVeil/drive',
              branch = 'feature',
              source = 'cache',
              age_seconds = 600,
              pull = {
                number = pr.number,
                url = url,
                base_ref_name = pr.baseRefName,
                base_ref_oid = pr.baseRefOid,
                head_ref_name = pr.headRefName,
                head_ref_oid = pr.headRefOid,
              },
            }),
          })
          assert(
            vim.wait(
              10000,
              function()
                return split.is_file_tree_visible()
                  and vim.b.diffhopper_diff_path == 'file.txt'
                  and core.get_buf_data(0)
                  and core.get_buf_data(0).ref_text == 'original\n'
              end,
              5
            ),
            'Cached preview did not render: ' .. vim.inspect(messages)
          )
          local session = split.get_session_id()
          if outcome == 'closed' then split.close() end
          scenario.gh_reply({
            code = 0,
            stderr = '',
            stdout = outcome == 'none' and '' or vim.json.encode(vim.tbl_extend('force', pr, {
              url = outcome == 'same' and url or url:gsub('1944', '2000'),
            })),
          })
          if outcome == 'different' then
            assert(
              vim.wait(
                10000,
                function()
                  return split.get_session_id() ~= session
                    and split.is_file_tree_visible()
                    and vim.b.diffhopper_diff_path == 'file.txt'
                end,
                5
              ),
              'Corrected URL did not replace the rendered view: ' .. vim.inspect(messages)
            )
          elseif outcome == 'none' then
            assert(vim.wait(10000, function() return not split.is_open() end, 5))
          else
            vim.wait(50, function() return false end, 5)
            eq(outcome == 'same', split.is_open())
            eq(outcome == 'same' and session or session + 1, split.get_session_id())
          end
          split.close()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if core.get_buf_data(buf) then core.disable(buf) end
          end
        end)
      end
    end
  end
end, debug.traceback)

vim.system, vim.notify, vim.fn.executable = system, notify, executable
vim.cmd.cd(vim.fn.fnameescape(sandbox))
vim.fn.delete(sandbox, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit()
else
  print('Passed ' .. count .. ' tests')
  vim.cmd.qa()
end
