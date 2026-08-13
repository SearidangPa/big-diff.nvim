local M = {}
local namespace = vim.api.nvim_create_namespace('BigDiffReviewComposer')

local function close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
end

M.open = function(review, on_save)
  local width = math.min(90, math.max(50, vim.o.columns - 10))
  local height = math.min(18, math.max(7, vim.o.lines - 10))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'big-diff-review://' .. review.id)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  local initial = review.comment or ''
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial == '' and { '' } or vim.split(initial, '\n', { plain = true }))
  vim.bo[buf].modified = false

  local anchor_first = review.side == 'old' and review.ref_line_start or review.line_start
  local anchor_last = review.side == 'old' and review.ref_line_end or review.line_end
  local range = anchor_first == anchor_last and tostring(anchor_first) or string.format('%d-%d', anchor_first, anchor_last)
  local metadata = {
    { { string.format('Review: %s:%s [%s]', review.file_path, range, review.side), 'Title' } },
    { { 'Target: ' .. tostring(review.source_target or 'Git index'), 'Comment' } },
    { { 'Write the review below; <C-s> or :write saves.', 'Comment' } },
  }
  vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, { virt_lines = metadata, virt_lines_above = true })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', row = math.floor((vim.o.lines - height) / 2 - 1), col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = 'minimal', border = 'rounded', title = ' Code review ', title_pos = 'center',
  })
  vim.wo[win].wrap = true

  local save = function()
    local comment = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    if comment == '' then vim.notify('(big-diff review) A review comment cannot be empty', vim.log.levels.WARN); return end
    on_save(comment)
    vim.bo[buf].modified = false
    close_window(win)
  end
  local cancel = function(force)
    if not force and vim.bo[buf].modified then
      local choice = vim.fn.confirm('Discard the changed review draft?', '&Discard\n&Keep editing', 2)
      if choice ~= 1 then return end
    end
    vim.bo[buf].modified = false
    close_window(win)
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = save, desc = 'Save code review comment' })
  vim.keymap.set('n', '<C-s>', save, { buffer = buf, desc = 'Save review' })
  vim.keymap.set('i', '<C-s>', function() vim.cmd('stopinsert'); save() end, { buffer = buf, desc = 'Save review' })
  vim.keymap.set('n', '<Esc>', function() cancel(false) end, { buffer = buf, nowait = true, desc = 'Close review draft' })
  vim.keymap.set('i', '<Esc>', function() vim.cmd('stopinsert'); vim.schedule(function() cancel(false) end) end,
    { buffer = buf, nowait = true, desc = 'Close review draft' })
  vim.keymap.set({ 'n', 'i' }, '<C-c>', function() cancel(true) end, { buffer = buf, desc = 'Cancel review draft' })
  vim.cmd('startinsert')
end

return M
