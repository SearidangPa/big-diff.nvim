local M = {}

local function first_line(review)
  return review.side == 'old' and review.ref_line_start or review.line_start
end

local function summary(comment)
  local text = (comment or ''):gsub('%s+', ' ')
  return #text > 55 and text:sub(1, 52) .. '...' or text
end

M.open = function(reviews, handlers)
  local width = math.min(120, math.max(70, vim.o.columns - 8))
  local height = math.min(math.max(#reviews + 2, 6), math.max(6, vim.o.lines - 8))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'big-diff-review-list'

  local rows, row_map = {}, {}
  if #reviews == 0 then
    rows[1] = 'No reviews. Use :BigDiffReviewAdd on a changed hunk.'
  else
    for index, review in ipairs(reviews) do
      local marker = review.status == 'stale' and '!' or '●'
      local first = first_line(review)
      local last = review.side == 'old' and review.ref_line_end or review.line_end
      local range = first == last and tostring(first) or string.format('%d-%d', first, last)
      rows[index] = string.format('%s %-9s %s:%s [%s]  %s', marker, review.status, review.file_path, range, review.side, summary(review.comment))
      row_map[index] = review.id
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', row = math.floor((vim.o.lines - height) / 2 - 1), col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = 'minimal', border = 'rounded', title = ' Reviews ', title_pos = 'center',
    footer = ' <CR> jump  e edit  d delete  r refresh  s submit  q close ', footer_pos = 'center',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local selected_id = function() return row_map[vim.api.nvim_win_get_cursor(win)[1]] end
  local close = function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  vim.keymap.set('n', '<CR>', function() local id = selected_id(); if id then close(); handlers.jump(id) end end, { buffer = buf })
  vim.keymap.set('n', 'e', function() local id = selected_id(); if id then close(); handlers.edit(id) end end, { buffer = buf })
  vim.keymap.set('n', 'd', function()
    local id = selected_id()
    if id and vim.fn.confirm('Delete this review?', '&Delete\n&Keep', 2) == 1 then close(); handlers.delete(id); handlers.reopen() end
  end, { buffer = buf })
  vim.keymap.set('n', 'r', function() close(); handlers.revalidate(); handlers.reopen() end, { buffer = buf })
  vim.keymap.set('n', 's', function() close(); handlers.submit() end, { buffer = buf })
end

return M
