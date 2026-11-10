local M = {}

-- Work in screen cells, not bytes, and keep combining characters together.
local function take(text, width, from_end)
  local count = vim.fn.strchars(text, true)
  local result = ''
  for i = 1, count do
    local index = from_end and count - i or i - 1
    local char = vim.fn.strcharpart(text, index, 1, true)
    local candidate = from_end and char .. result or result .. char
    if vim.fn.strdisplaywidth(candidate) > width then break end
    result = candidate
  end
  return result
end

function M.truncate(text, width)
  width = math.max(0, width)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local available = width - vim.fn.strdisplaywidth('…')
  if available < 0 then return '' end
  -- Keep more of the suffix: it usually distinguishes similarly named files,
  -- and includes the extension.
  local tail = take(text, math.ceil(available * 0.6), true)
  local head = take(text, available - vim.fn.strdisplaywidth(tail), false)
  return head .. '…' .. tail
end

local status_highlights = {
  A = 'BigDiffTreeAdded',
  D = 'BigDiffTreeRemoved',
  M = 'BigDiffTreeModified',
  T = 'BigDiffTreeModified',
  R = 'BigDiffTreeRenamed',
  C = 'BigDiffTreeRenamed',
  U = 'BigDiffTreeConflict',
  ['?'] = 'BigDiffUntracked',
}

local function group_files(files)
  local groups, names = {}, {}
  for index, entry in ipairs(files) do
    local path = type(entry) == 'table' and entry.path or entry
    local parent = vim.fn.fnamemodify(path, ':h')
    if not groups[parent] then
      groups[parent] = {}
      names[#names + 1] = parent
    end
    local status = type(entry) == 'table' and entry.status or 'M'
    if type(entry) == 'table' and entry.untracked then status = '?' end
    table.insert(groups[parent], { index = index, path = path, status = (status or 'M'):sub(1, 1) })
  end
  table.sort(names)
  for _, entries in pairs(groups) do
    table.sort(entries, function(a, b) return a.path < b.path end)
  end
  return groups, names
end

function M.preferred_width(files, available)
  local groups, names = group_files(files)
  local width = 36
  local directory_padding = vim.fn.strdisplaywidth(' ▾ /  ')
  local file_padding = vim.fn.strdisplaywidth('   ╰ M  ') + 1
  for _, name in ipairs(names) do
    width =
      math.max(width, vim.fn.strdisplaywidth(vim.fn.strtrans(name)) + #tostring(#groups[name]) + directory_padding)
    for _, entry in ipairs(groups[name]) do
      local filename = vim.fn.strtrans(vim.fn.fnamemodify(entry.path, ':t'))
      width = math.max(width, vim.fn.strdisplaywidth(filename) + file_padding)
    end
  end
  -- Leave at least 60% of the original window for code, even on small screens.
  return math.max(1, math.min(width, 48, math.floor(available * 0.4)))
end

function M.layout(files, width)
  local groups, names = group_files(files)
  local result = { lines = {}, rows = {}, groups = {}, line_to_file_index = {} }

  local function add(line, row)
    if vim.fn.strdisplaywidth(line) > width then line = take(line, math.max(0, width), false) end
    for _, span in ipairs(row.highlights) do
      span[1], span[2] = math.min(span[1], #line), math.min(span[2], #line)
    end
    result.lines[#result.lines + 1] = line
    result.rows[#result.rows + 1] = row
    result.line_to_file_index[#result.lines] = row.file_index or false
  end

  for _, name in ipairs(names) do
    if #result.lines > 0 then add('', { highlights = {} }) end
    local entries = groups[name]
    local count = tostring(#entries)
    local prefix = ' ▾ '
    local label = M.truncate(vim.fn.strtrans(name .. '/'), width - vim.fn.strdisplaywidth(prefix) - #count - 3)
    local left = prefix .. label
    local padding = string.rep(' ', math.max(1, width - vim.fn.strdisplaywidth(left) - #count - 1))
    local line = left .. padding .. count .. ' '
    local count_col = #left + #padding
    local group = { path = name, first = #result.lines + 1 }
    add(line, {
      path = name,
      highlights = {
        { 0, #left, 'BigDiffDir' },
        { count_col, count_col + #count, 'BigDiffTreeCount' },
      },
    })

    for index, entry in ipairs(entries) do
      local guide = index == #entries and '   ╰ ' or '   │ '
      local file_prefix = guide .. entry.status .. '  '
      local filename = vim.fn.strtrans(vim.fn.fnamemodify(entry.path, ':t'))
      local display = M.truncate(filename, width - vim.fn.strdisplaywidth(file_prefix) - 1)
      add(file_prefix .. display, {
        path = entry.path,
        file_index = entry.index,
        filename_col = #file_prefix,
        highlights = {
          { 0, #guide, 'BigDiffTreeGuide' },
          { #guide, #guide + #entry.status, status_highlights[entry.status] or 'BigDiffTreeModified' },
          { #file_prefix, #file_prefix + #display, 'BigDiffTreeFile' },
        },
      })
    end
    group.last = #result.lines
    result.groups[#result.groups + 1] = group
  end

  if #result.lines == 0 then
    local message = M.truncate(' No files to show', width)
    add(message, { highlights = { { 0, #message, 'BigDiffTreeCount' } } })
  end
  return result
end

return M
