-- Run from the repository root: nvim --headless -u NONE -l tests/tree.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.g.minidiff_disable = true
require('big-diff.nvim').setup()

local tree = require('big-diff.nvim.split.tree')
local ui = require('big-diff.nvim.split.ui')
local root = vim.fn.tempname()
local count = 0
vim.fn.mkdir(root, 'p')

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), 'expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end

local function test(name, fn)
  fn()
  count = count + 1
  print('ok ' .. count .. ' - ' .. name)
end

local function with_tree(files, current, fn, hidden_count)
  vim.o.columns = 160
  vim.o.laststatus = 2
  vim.cmd('silent! only')
  vim.cmd.redraw()
  vim.cmd.enew()
  local main = vim.api.nvim_get_current_win()
  local buffers = {}
  local fixture = { main = main }

  function fixture.show(path, deleted)
    local buf = vim.fn.bufadd(root .. '/' .. path)
    vim.fn.bufload(buf)
    buffers[buf] = true
    vim.b[buf].big_diff_split_path = deleted and path or nil
    vim.api.nvim_win_set_buf(main, buf)
    return buf
  end
  fixture.show(current or 'not-in-diff.txt')
  vim.wo[main].cursorline = true
  vim.wo[main].cursorcolumn = true
  vim.wo[main].colorcolumn = '80'
  vim.wo[main].wrap = true

  fixture.expected_width = tree.preferred_width(files, vim.api.nvim_win_get_width(main))
  local buf, win = ui.create_split_buffer(files)
  fixture.buf, fixture.win = buf, win
  local map, highlight = ui.render_files(buf, win, files, root, main, hidden_count)
  fixture.map = map
  fixture.navigation = ui.setup_keymaps(
    buf,
    win,
    files,
    root,
    main,
    'HEAD',
    map,
    highlight,
    function(_, _, entry, _, on_open)
      local path = type(entry) == 'table' and entry.path or entry
      fixture.pending = function()
        vim.api.nvim_set_current_win(main)
        fixture.show(path, type(entry) == 'table' and entry.status == 'D')
        on_open()
      end
      if not fixture.defer then fixture.pending() end
    end,
    function() fixture.toggled_tests = true end
  )
  fixture.navigation.sync_current_file()

  function fixture.line(index)
    for line, file_index in ipairs(map) do
      if file_index == index then return line end
    end
  end

  function fixture.active_rows()
    local rows = {}
    local ns = vim.api.nvim_get_namespaces().MiniDiffHighlightCurrent
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if mark[4].line_hl_group then rows[#rows + 1] = mark[2] + 1 end
    end
    return rows
  end

  function fixture.press(key)
    vim.api.nvim_set_current_win(win)
    local mapping = vim.fn.maparg(key, 'n', false, true)
    if mapping.callback then
      mapping.callback()
    else
      vim.cmd(assert(mapping.rhs:match('^<Cmd>(.*)<CR>$')))
    end
  end

  local ok, err = xpcall(function() fn(fixture) end, debug.traceback)
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  for buffer in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  end
  if not ok then error(err) end
end

local files = {
  { path = 'server/notification/notification_handler_share.go', status = 'M' },
  { path = 'client/notification/observability.go', status = 'A' },
  { path = 'server/notification/notification_handler_update.go', status = 'M' },
  { path = 'server/notification/new_observer.go', status = 'A', untracked = true },
  { path = 'server/notification/removed.go', status = 'D' },
}

local ok, err = xpcall(function()
  test('chooses a content-aware width without taking space away from code', function()
    eq(18, tree.preferred_width({ 'a.go' }, 160))
    eq(28, tree.preferred_width(files, 160))
    eq(28, tree.preferred_width({ string.rep('long_', 20) .. 'file.go' }, 160))
    eq(16, tree.preferred_width(files, 80))
    eq(10, tree.preferred_width(files, 50))
  end)

  test('preserves full filenames and extensions when they fit', function()
    local layout = tree.layout({ 'notification/notification_handler_share.go' }, 48)
    eq('   ╰ M  notification_handler_share.go', layout.lines[2])
    eq('notification/', layout.lines[1]:match('▾ (.-)%s+1'))
  end)

  test('truncates only once and keeps the meaningful suffix and extension', function()
    eq('notification_handler_share.go', tree.truncate('notification_handler_share.go', 40))
    local short = tree.truncate('notification_handler_share.go', 22)
    assert(short:find('…', 1, true), short)
    assert(short:match('share%.go$'), short)
    eq(22, vim.fn.strdisplaywidth(short))
  end)

  test('uses full parent paths, deterministic ordering, and dense line mappings', function()
    local layout = tree.layout(files, 48)
    eq('client/notification', layout.groups[1].path)
    eq('server/notification', layout.groups[2].path)
    eq({ false, 2, false, false, 4, 1, 3, 5 }, layout.line_to_file_index)
    eq(#layout.lines, #layout.line_to_file_index)
    eq('   │ ?  new_observer.go', layout.lines[5])
  end)

  test('handles unicode, combining characters, control characters, and tiny widths', function()
    local names = {
      '通知/通知_handler_共有_test.go',
      'café/very_long_café_notification_service.go',
      'a/file\twith\ncontrols.go',
      'plain-name-without-underscores-and-a-long-suffix.lua',
    }
    for _, ambiwidth in ipairs({ 'single', 'double' }) do
      vim.o.ambiwidth = ambiwidth
      for width = 1, 48 do
        local layout = tree.layout(names, width)
        for row, line in ipairs(layout.lines) do
          assert(vim.fn.strdisplaywidth(line) <= width, vim.inspect({ width, line }))
          assert(not line:find('[\t\n]'))
          for _, span in ipairs(layout.rows[row].highlights) do
            assert(span[1] <= span[2] and span[2] <= #line)
          end
        end
      end
    end
    vim.o.ambiwidth = 'single'
  end)

  test('keeps all tree statuses foreground-only, including with unusual themes', function()
    local names = {
      'BigDiffTreeFile',
      'BigDiffDir',
      'BigDiffTreeGuide',
      'BigDiffTreeCount',
      'BigDiffTreeAdded',
      'BigDiffTreeModified',
      'BigDiffTreeRemoved',
      'BigDiffTreeRenamed',
      'BigDiffTreeConflict',
      'BigDiffUntracked',
      'BigDiffTestsHidden',
    }
    local original = {}
    for _, name in ipairs({ 'Normal', 'Comment', 'DiagnosticWarn' }) do
      original[name] = vim.api.nvim_get_hl(0, { name = name })
    end
    for _, background in ipairs({ 'dark', 'light' }) do
      vim.o.background = background
      vim.api.nvim_set_hl(0, 'Normal', { fg = 0x888888, bg = 0x222222 })
      vim.api.nvim_set_hl(0, 'Comment', { fg = 0x777777, bg = 0x333333, italic = true })
      vim.api.nvim_set_hl(0, 'DiagnosticWarn', { fg = 0xffaa00, bg = 0x444444 })
      require('big-diff.nvim.viz').create_default_hl()
      for _, name in ipairs(names) do
        local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
        eq(nil, hl.bg)
        eq(nil, hl.reverse)
        assert(hl.fg, name)
      end
      assert(vim.api.nvim_get_hl(0, { name = 'BigDiffTreeCurrent' }).bg ~= 0x222222)
    end
    vim.o.background = 'dark'
    for name, hl in pairs(original) do
      vim.api.nvim_set_hl(0, name, hl)
    end
    require('big-diff.nvim.viz').create_default_hl()
  end)

  test('disables inherited row/column decoration and wrapping in the tree only', function()
    with_tree(files, files[1].path, function(f)
      eq(f.expected_width, vim.api.nvim_win_get_width(f.win))
      for _, option in ipairs({ 'wrap', 'cursorline', 'cursorcolumn', 'number', 'relativenumber', 'list' }) do
        eq(false, vim.wo[f.win][option])
      end
      eq('', vim.wo[f.win].colorcolumn)
      eq('', vim.wo[f.win].statuscolumn)
      eq(true, vim.wo[f.main].cursorline)
      eq(true, vim.wo[f.main].wrap)
      local header = vim.api.nvim_eval_statusline(vim.wo[f.win].winbar, { winid = f.win }).str
      assert(header:find('CHANGED FILES', 1, true))
      assert(header:find('5', 1, true))
    end)
  end)

  test('highlights exactly the open file, not added/untracked files or the tree cursor', function()
    with_tree(files, files[1].path, function(f)
      eq({ f.line(1) }, f.active_rows())
      vim.api.nvim_win_set_cursor(f.win, { f.line(4), 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = f.buf })
      eq({ f.line(1) }, f.active_rows())
      assert(vim.wo[f.win].statusline:find(files[4].path, 1, true))
      local marks = vim.api.nvim_buf_get_extmarks(f.buf, -1, 0, -1, { details = true })
      local backgrounds = 0
      for _, mark in ipairs(marks) do
        if mark[4].line_hl_group then backgrounds = backgrounds + 1 end
      end
      eq(1, backgrounds)
    end)
  end)

  test('does not invent a current file when the main buffer is outside the diff', function()
    with_tree(files, nil, function(f) eq({}, f.active_rows()) end)
  end)

  test('syncs external buffer switches and clears selection for unrelated buffers', function()
    with_tree(files, files[1].path, function(f)
      f.show(files[2].path)
      eq({ f.line(2) }, f.active_rows())
      f.show('unrelated.go')
      eq({}, f.active_rows())
      f.show(files[5].path, true)
      eq({ f.line(5) }, f.active_rows())
    end)
  end)

  test('does not reset the browsing cursor when focus returns to the tree', function()
    with_tree(files, files[1].path, function(f)
      vim.api.nvim_win_set_cursor(f.win, { f.line(4), 0 })
      vim.api.nvim_set_current_win(f.main)
      vim.api.nvim_set_current_win(f.win)
      eq(f.line(4), vim.api.nvim_win_get_cursor(f.win)[1])
      eq({ f.line(1) }, f.active_rows())
    end)
  end)

  test('waits for async file opening before changing the highlighted file', function()
    with_tree(files, files[1].path, function(f)
      f.defer = true
      vim.api.nvim_win_set_cursor(f.win, { f.line(2), 0 })
      f.press('<CR>')
      eq({ f.line(1) }, f.active_rows())
      f.pending()
      eq({ f.line(2) }, f.active_rows())
      eq(root .. '/' .. files[2].path, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(f.main)))
    end)
  end)

  test('collapses directories with h, expands with l, and toggles with Enter', function()
    with_tree(files, files[1].path, function(f)
      vim.api.nvim_win_set_cursor(f.win, { f.line(1), 0 })
      f.press('h')
      local first = vim.fn.foldclosed(f.line(1))
      assert(first > 0)
      eq(false, f.map[first])
      f.press('l')
      eq(-1, vim.fn.foldclosed(f.line(1)))
      vim.api.nvim_win_set_cursor(f.win, { first, 0 })
      f.press('<CR>')
      eq(first, vim.fn.foldclosed(first))
      f.press('<CR>')
      eq(-1, vim.fn.foldclosed(first))
    end)
  end)

  test('next/previous navigation follows tree order and opens collapsed groups', function()
    with_tree(files, files[1].path, function(f)
      vim.cmd('normal! zM')
      f.navigation.open_next_file()
      eq({ f.line(3) }, f.active_rows())
      eq(-1, vim.fn.foldclosed(f.line(3)))
      f.navigation.open_previous_file()
      eq({ f.line(1) }, f.active_rows())
      f.show(files[5].path, true)
      f.navigation.open_next_file()
      eq({ f.line(2) }, f.active_rows())
      f.navigation.open_previous_file()
      eq({ f.line(5) }, f.active_rows())
    end)
  end)

  test('redraws names on resize without losing selection or collapsed directories', function()
    with_tree(files, files[1].path, function(f)
      f.show(files[3].path)
      vim.api.nvim_set_current_win(f.win)
      vim.api.nvim_win_set_cursor(f.win, { f.line(2), 0 })
      f.press('h')
      local closed = vim.fn.foldclosed(f.line(2))
      vim.api.nvim_win_set_width(f.win, 25)
      vim.api.nvim_exec_autocmds('WinResized', {})
      eq({ f.line(3) }, f.active_rows())
      eq(closed, vim.fn.foldclosed(f.line(2)))
      for _, line in ipairs(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)) do
        assert(vim.fn.strdisplaywidth(line) <= 25, line)
      end
      vim.api.nvim_win_set_width(f.win, 48)
      vim.api.nvim_exec_autocmds('WinResized', {})
      assert(
        vim.api
          .nvim_buf_get_lines(f.buf, f.line(3) - 1, f.line(3), false)[1]
          :find('notification_handler_update.go', 1, true)
      )
      eq({ f.line(3) }, f.active_rows())
      f.show('unrelated.go')
      vim.api.nvim_win_set_width(f.win, 26)
      vim.api.nvim_exec_autocmds('WinResized', {})
      eq({}, f.active_rows())
    end)
  end)

  test('shows filter state and handles an empty filtered list without a selection', function()
    with_tree({}, nil, function(f)
      eq({}, f.active_rows())
      local header = vim.api.nvim_eval_statusline(vim.wo[f.win].winbar, { winid = f.win }).str
      assert(header:find('3 h', 1, true), header)
      eq({ ' No files to show' }, vim.api.nvim_buf_get_lines(f.buf, 0, -1, false))
      f.navigation.open_next_file()
      f.navigation.open_previous_file()
      f.press('<Tab>')
      eq(true, f.toggled_tests)
    end, 3)
  end)

  test('escapes percent signs in the full path footer', function()
    with_tree({ 'dir/file%name.go' }, 'dir/file%name.go', function(f)
      local footer = vim.api.nvim_eval_statusline(vim.wo[f.win].statusline, { winid = f.win }).str
      assert(footer:find('dir/file%name.go', 1, true), footer)
    end)
  end)

  test('removes window observers when the tree is wiped', function()
    local group_names
    with_tree(files, files[1].path, function(f)
      group_names = { 'BigDiffTreeLayout' .. f.buf, 'BigDiffSplitSync' .. f.buf }
      for _, name in ipairs(group_names) do
        assert(#vim.api.nvim_get_autocmds({ group = name }) > 0)
      end
    end)
    for _, name in ipairs(group_names) do
      eq(false, pcall(vim.api.nvim_get_autocmds, { group = name }))
    end
    vim.api.nvim_exec_autocmds('WinResized', {})
  end)
end, debug.traceback)

vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit()
else
  print('Passed ' .. count .. ' tree tests')
  vim.cmd.qa()
end
