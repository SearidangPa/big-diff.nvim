local M = {}
local tree = require('big-diff.nvim.split.tree')

local highlight_ns = vim.api.nvim_create_namespace('MiniDiffHighlight')
local current_line_ns = vim.api.nvim_create_namespace('MiniDiffHighlightCurrent')

local function find_current_file_index(files, git_root, main_win)
  if not main_win or not vim.api.nvim_win_is_valid(main_win) then return end
  local buf = vim.api.nvim_win_get_buf(main_win)
  local ok, diff_path = pcall(vim.api.nvim_buf_get_var, buf, 'big_diff_split_path')
  local current_path = vim.api.nvim_buf_get_name(buf)
  for index, entry in ipairs(files) do
    local path = type(entry) == 'table' and entry.path or entry
    if ok and diff_path ~= '' then
      if path == diff_path then return index end
    elseif current_path ~= '' and not (type(entry) == 'table' and entry.status == 'D') then
      local absolute_path = vim.fs.normalize(git_root .. '/' .. path)
      if vim.fn.resolve(absolute_path) == vim.fn.resolve(vim.fs.normalize(current_path)) then return index end
    end
  end
end

local function reveal_file(window_number, line)
  if not line or not vim.api.nvim_win_is_valid(window_number) then return end
  vim.api.nvim_win_call(window_number, function()
    vim.api.nvim_win_set_cursor(window_number, { line, 0 })
    vim.cmd('silent! normal! zv')
  end)
end

function M.create_split_buffer(files)
  local width = tree.preferred_width(files or {}, vim.api.nvim_win_get_width(0))
  vim.cmd('topleft vnew')
  local buffer_number = vim.api.nvim_get_current_buf()
  local window_number = vim.api.nvim_get_current_win()

  vim.bo[buffer_number].buftype = 'nofile'
  vim.bo[buffer_number].bufhidden = 'wipe'
  vim.bo[buffer_number].swapfile = false
  vim.bo[buffer_number].filetype = 'minidiff'
  vim.bo[buffer_number].buflisted = false

  local options = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    statuscolumn = '',
    foldcolumn = '0',
    winfixwidth = true,
    wrap = false,
    list = false,
    spell = false,
    cursorline = false,
    cursorcolumn = false,
    colorcolumn = '',
    foldmethod = 'manual',
    foldenable = true,
    foldlevel = 99,
    foldtext = "substitute(getline(v:foldstart), '▾', '▸', '')",
    winhighlight = table.concat({
      'Normal:BigDiffTreeNormal',
      'NormalNC:BigDiffTreeNormal',
      'WinBar:BigDiffTreeWinBar',
      'WinBarNC:BigDiffTreeWinBar',
      'StatusLine:BigDiffTreeStatusLine',
      'StatusLineNC:BigDiffTreeStatusLine',
      'Folded:BigDiffDir',
      'CursorLine:BigDiffTreeNormal',
      'CursorColumn:BigDiffTreeNormal',
      'EndOfBuffer:BigDiffTreeNormal',
    }, ','),
  }
  for name, value in pairs(options) do
    vim.wo[window_number][name] = value
  end
  vim.opt_local.fillchars:append({ fold = ' ', eob = ' ' })
  vim.api.nvim_win_resize(window_number, width, -1)

  return buffer_number, window_number
end

function M.render_header(window_number, count, hidden_count)
  local width = vim.api.nvim_win_get_width(window_number)
  local label = width < 16 and 'FILES' or 'CHANGED FILES'
  local hidden = ''
  if hidden_count ~= nil then
    hidden = width < 32 and (' · ' .. hidden_count .. ' hidden')
      or (' · ' .. hidden_count .. (hidden_count == 1 and ' test hidden' or ' tests hidden'))
  end
  vim.wo[window_number].winbar = table.concat({
    '%#BigDiffTreeHeader# ',
    label,
    '%#BigDiffTestsHidden#',
    hidden,
    '%#BigDiffTreeCount#%=',
    tostring(count),
    ' ',
  })
end

function M.render_files(buffer_number, window_number, files, git_root, main_win, hidden_count)
  local line_to_file_index = {}
  local layout, current_line, rendered_width
  local current_index = find_current_file_index(files, git_root, main_win)

  local function update_footer()
    local row = layout.rows[vim.api.nvim_win_get_cursor(window_number)[1]]
    local path = row and row.file_index and row.path
    if not path and current_line then path = layout.rows[current_line].path end
    local label = path and vim.fn.strtrans(path) or 'Enter open · h/l fold · Tab tests'
    -- Filenames can contain statusline directives.
    vim.wo[window_number].statusline = '%#BigDiffTreeStatusLine# %<' .. label:gsub('%%', '%%%%') .. ' '
  end

  local function apply_line_highlights()
    vim.api.nvim_buf_clear_namespace(buffer_number, highlight_ns, 0, -1)
    for line_nr, row in ipairs(layout.rows) do
      for _, span in ipairs(row.highlights) do
        if span[2] > span[1] then
          vim.api.nvim_buf_set_extmark(buffer_number, highlight_ns, line_nr - 1, span[1], {
            end_col = span[2],
            hl_group = span[3],
          })
        end
      end
    end
  end

  local function highlight_current_file(line_override)
    if line_override == false then
      current_line = nil
    elseif line_override then
      current_line = line_override
    end
    vim.api.nvim_buf_clear_namespace(buffer_number, current_line_ns, 0, -1)
    local row = current_line and layout.rows[current_line]
    current_index = row and row.file_index or nil
    if row and row.file_index then
      vim.api.nvim_buf_set_extmark(buffer_number, current_line_ns, current_line - 1, 0, {
        line_hl_group = 'BigDiffTreeCurrent',
        virt_text = { { '›', 'BigDiffTreeCurrentFile' } },
        virt_text_win_col = 1,
        virt_text_pos = 'overlay',
        hl_mode = 'combine',
        priority = 210,
      })
      if row.filename_col < #layout.lines[current_line] then
        vim.api.nvim_buf_set_extmark(buffer_number, current_line_ns, current_line - 1, row.filename_col, {
          end_col = #layout.lines[current_line],
          hl_group = 'BigDiffTreeCurrentFile',
          hl_mode = 'combine',
          priority = 211,
        })
      end
    end
    update_footer()
  end

  local function render()
    local closed = {}
    local view = vim.api.nvim_win_call(window_number, function()
      for _, group in ipairs(layout and layout.groups or {}) do
        if vim.fn.foldclosed(group.first) ~= -1 then closed[group.path] = true end
      end
      return vim.fn.winsaveview()
    end)

    rendered_width = vim.api.nvim_win_get_width(window_number)
    layout = tree.layout(files, rendered_width)
    for line in pairs(line_to_file_index) do
      line_to_file_index[line] = nil
    end
    for line, file_index in ipairs(layout.line_to_file_index) do
      line_to_file_index[line] = file_index
      if file_index == current_index then current_line = line end
    end
    vim.bo[buffer_number].modifiable = true
    vim.api.nvim_buf_set_lines(buffer_number, 0, -1, false, layout.lines)
    vim.bo[buffer_number].modifiable = false
    apply_line_highlights()
    M.render_header(window_number, #files, hidden_count)

    vim.api.nvim_win_call(window_number, function()
      vim.cmd('silent! normal! zE')
      for _, group in ipairs(layout.groups) do
        vim.cmd(string.format('%d,%dfold', group.first, group.last))
      end
      vim.cmd('silent! normal! zR')
      for _, group in ipairs(layout.groups) do
        if closed[group.path] then
          vim.api.nvim_win_set_cursor(window_number, { group.first, 0 })
          vim.cmd('silent! normal! zc')
        end
      end
      vim.fn.winrestview(view)
    end)
    highlight_current_file()
  end

  render()

  local group = vim.api.nvim_create_augroup('BigDiffTreeLayout' .. buffer_number, { clear = true })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = group,
    callback = function()
      if vim.api.nvim_win_is_valid(window_number) and vim.api.nvim_win_get_width(window_number) ~= rendered_width then
        render()
      end
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, buffer = buffer_number, callback = update_footer })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buffer_number,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
  })

  return line_to_file_index, highlight_current_file
end

function M.setup_keymaps(
  buffer_number,
  window_number,
  files,
  git_root,
  main_win,
  base,
  line_to_file_index,
  highlight_current_file,
  open_file_in_main_win,
  toggle_exclude_tests
)
  local sync_current_file
  local synced_index
  local file_sequence, file_sequence_pos = {}, {}
  for _, index in ipairs(line_to_file_index) do
    if index and not file_sequence_pos[index] then
      file_sequence_pos[index] = #file_sequence + 1
      file_sequence[#file_sequence + 1] = index
    end
  end

  local function file_index_to_line(file_index)
    for line_nr, index in ipairs(line_to_file_index) do
      if index == file_index then return line_nr end
    end
  end

  local function open_file_by_index(file_index)
    local entry = file_index and files[file_index]
    if not entry or not vim.api.nvim_win_is_valid(main_win) then return end
    -- Wait for the actual buffer switch: the tree cursor is not the open file.
    open_file_in_main_win(base, git_root, entry, main_win, sync_current_file)
  end

  if toggle_exclude_tests then
    vim.keymap.set('n', '<Tab>', toggle_exclude_tests, {
      buffer = buffer_number,
      nowait = true,
      desc = 'Toggle test files',
    })
  end

  vim.keymap.set('n', '<CR>', function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    if line_to_file_index[line] then
      open_file_by_index(line_to_file_index[line])
    elseif vim.fn.foldlevel(line) > 0 then
      vim.cmd('silent! normal! za')
    end
  end, { buffer = buffer_number, nowait = true, desc = 'Open file or toggle directory' })
  vim.keymap.set('n', 'h', '<Cmd>silent! normal! zc<CR>', { buffer = buffer_number, desc = 'Collapse directory' })
  vim.keymap.set('n', 'l', '<Cmd>silent! normal! zo<CR>', { buffer = buffer_number, desc = 'Expand directory' })
  vim.keymap.set(
    'n',
    'g?',
    function()
      vim.notify(table.concat({
        'Enter: open file / toggle directory',
        'h/l: collapse / expand · zM/zR: collapse / expand all',
        'Tab: toggle test files',
      }, '\n'))
    end,
    { buffer = buffer_number, desc = 'File tree help' }
  )

  sync_current_file = function()
    if not vim.api.nvim_win_is_valid(main_win) or not vim.api.nvim_buf_is_valid(buffer_number) then return end
    local index = find_current_file_index(files, git_root, main_win)
    local line = index and file_index_to_line(index)
    highlight_current_file(line or false)
    if line and index ~= synced_index then reveal_file(window_number, line) end
    synced_index = index
  end

  local sync_group = vim.api.nvim_create_augroup('BigDiffSplitSync' .. buffer_number, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'WinEnter' }, {
    group = sync_group,
    callback = sync_current_file,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = sync_group,
    buffer = buffer_number,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, sync_group) end,
  })

  local function step_file(direction)
    if #file_sequence == 0 then return end
    local index = find_current_file_index(files, git_root, main_win)
    local pos = index and file_sequence_pos[index]
    local next_pos = pos and ((pos - 1 + direction) % #file_sequence + 1) or (direction == 1 and 1 or #file_sequence)
    local next_index = file_sequence[next_pos]
    open_file_by_index(next_index)
    reveal_file(window_number, file_index_to_line(next_index))
  end

  return {
    open_next_file = function() step_file(1) end,
    open_previous_file = function() step_file(-1) end,
    sync_current_file = sync_current_file,
  }
end

return M
