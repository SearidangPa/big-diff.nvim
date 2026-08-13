local M = {}

local function split_text(text)
  if type(text) ~= 'string' then return {} end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function hunk_range(hunk)
  if hunk.buf_count > 0 then return hunk.buf_start, hunk.buf_start + hunk.buf_count - 1 end
  local row = math.max(hunk.buf_start, 1)
  return row, row
end

M.hunks_in_range = function(hunks, first, last)
  local result = {}
  for _, hunk in ipairs(hunks or {}) do
    local h_first, h_last = hunk_range(hunk)
    if math.max(first, h_first) <= math.min(last, h_last) then table.insert(result, hunk) end
  end
  return result
end

local function get_head(repo_root)
  local output = vim.fn.system({ 'git', '-C', repo_root, 'rev-parse', 'HEAD' })
  return vim.v.shell_error == 0 and vim.trim(output) or nil
end

local function relative_path(repo_root, absolute)
  repo_root, absolute = vim.fs.normalize(repo_root), vim.fs.normalize(absolute)
  if absolute == repo_root then return '' end
  local prefix = repo_root .. '/'
  if absolute:sub(1, #prefix) ~= prefix then return nil end
  return absolute:sub(#prefix + 1)
end

local function excerpt(lines, first, last)
  local result = {}
  for line = math.max(1, first), math.min(#lines, last) do result[#result + 1] = lines[line] end
  return result
end

M.capture = function(session, buf_id, first, last, chosen_hunks)
  local data = _G.MiniDiff and _G.MiniDiff.get_buf_data(buf_id)
  if not data or type(data.ref_text) ~= 'string' then return nil, 'Current buffer has no diff data yet' end
  local hunks = chosen_hunks or M.hunks_in_range(data.hunks, first, last)
  if #hunks == 0 then return nil, 'Selection does not intersect a changed hunk' end

  local deletion_only = true
  for _, hunk in ipairs(hunks) do if hunk.type ~= 'delete' then deletion_only = false end end
  local side = deletion_only and 'old' or 'new'
  local buf_lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  local ref_lines = split_text(data.ref_text)
  local selected, line_start, line_end, ref_start, ref_end

  if side == 'old' then
    ref_start, ref_end = math.huge, 0
    for _, hunk in ipairs(hunks) do
      ref_start = math.min(ref_start, hunk.ref_start)
      ref_end = math.max(ref_end, hunk.ref_start + hunk.ref_count - 1)
    end
    line_start, line_end = math.max(first, 1), math.max(last, 1)
    selected = excerpt(ref_lines, ref_start, ref_end)
  else
    line_start, line_end = first, last
    selected = excerpt(buf_lines, first, last)
    ref_start, ref_end = math.huge, 0
    for _, hunk in ipairs(hunks) do
      if hunk.ref_count > 0 then
        ref_start = math.min(ref_start, hunk.ref_start)
        ref_end = math.max(ref_end, hunk.ref_start + hunk.ref_count - 1)
      end
    end
    if ref_start == math.huge then ref_start, ref_end = nil, nil end
  end

  local path = relative_path(session.repo_root, vim.api.nvim_buf_get_name(buf_id))
  if not path or path == '' then return nil, 'Buffer is outside the review repository' end
  local context_lines = session.config.context_lines or 3
  local source_lines = side == 'old' and ref_lines or buf_lines
  local source_first, source_last = side == 'old' and ref_start or line_start, side == 'old' and ref_end or line_end
  local source_target = data.source_target or { kind = 'git-index', ref = 'index' }

  return {
    repo_root = session.repo_root,
    file_path = path,
    scope = 'line',
    side = side,
    line_start = line_start,
    line_end = line_end,
    ref_line_start = ref_start,
    ref_line_end = ref_end,
    source_name = data.source_name or 'git',
    source_target = source_target.ref or source_target.kind or 'index',
    selected_text = table.concat(selected, '\n'),
    context_before = excerpt(source_lines, source_first - context_lines, source_first - 1),
    context_after = excerpt(source_lines, source_last + 1, source_last + context_lines),
    snapshot = {
      ref_hash = vim.fn.sha256(data.ref_text),
      buffer_hash = vim.fn.sha256(table.concat(buf_lines, '\n')),
      head = get_head(session.repo_root),
    },
    _buf_id = buf_id,
  }
end

local function find_sequence(lines, selected, around, context_before, context_after)
  local needles = vim.split(selected, '\n', { plain = true })
  if selected == '' or #needles == 0 then return nil end
  local low, high = math.max(1, around - 100), math.min(#lines - #needles + 1, around + 100)
  local matches = {}
  for first = low, high do
    local equal = true
    for index, needle in ipairs(needles) do if lines[first + index - 1] ~= needle then equal = false; break end end
    local last = first + #needles - 1
    if equal and type(context_before) == 'table' then
      for index, context in ipairs(context_before) do
        local row = first - #context_before + index - 1
        if row >= 1 and lines[row] ~= context then equal = false; break end
      end
    end
    if equal and type(context_after) == 'table' then
      for index, context in ipairs(context_after) do
        local row = last + index
        if row <= #lines and lines[row] ~= context then equal = false; break end
      end
    end
    if equal then matches[#matches + 1] = first end
  end
  if #matches ~= 1 then return nil end
  return matches[1], matches[1] + #needles - 1
end

local function intersects_changed_hunk(review, first, last)
  local output = vim.fn.systemlist({ 'git', '-C', review.repo_root, 'diff', '--no-color', '--unified=0', '--', review.file_path })
  if vim.v.shell_error ~= 0 then return false end
  for _, line in ipairs(output) do
    local old_start, old_count, new_start, new_count = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if old_start then
      old_start, new_start = tonumber(old_start), tonumber(new_start)
      old_count = old_count == '' and 1 or tonumber(old_count)
      new_count = new_count == '' and 1 or tonumber(new_count)
      local start = review.side == 'old' and old_start or new_start
      local count = review.side == 'old' and old_count or new_count
      if count > 0 and math.max(first, start) <= math.min(last, start + count - 1) then return true end
    end
  end
  return false
end

M.revalidate = function(review, buf_id, data)
  local lines
  if review.side == 'old' then
    if not data or type(data.ref_text) ~= 'string' then review.status = 'stale'; return false end
    lines = split_text(data.ref_text)
  elseif buf_id and vim.api.nvim_buf_is_valid(buf_id) then
    lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  else
    local ok, disk_lines = pcall(vim.fn.readfile, vim.fs.joinpath(review.repo_root, review.file_path))
    if not ok then review.status = 'stale'; return false end
    lines = disk_lines
  end

  local first = review.side == 'old' and review.ref_line_start or review.line_start
  local last = review.side == 'old' and review.ref_line_end or review.line_end
  local current = table.concat(excerpt(lines, first, last), '\n')
  if current ~= review.selected_text then
    first, last = find_sequence(lines, review.selected_text, first or 1, review.context_before, review.context_after)
    if not first then review.status = 'stale'; return false end
  end

  if not intersects_changed_hunk(review, first, last) then review.status = 'stale'; return false end
  if review.side == 'old' then review.ref_line_start, review.ref_line_end = first, last
  else review.line_start, review.line_end = first, last end
  if review.status == 'stale' then review.status = 'pending' end
  return true
end

return M
