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

function M.truncate(text, width, tail_ratio)
  width = math.max(0, width)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local available = width - vim.fn.strdisplaywidth('…')
  if available < 0 then return '' end
  -- Keep more of the suffix: it usually distinguishes similarly named files,
  -- and includes the extension.
  local tail = take(text, math.ceil(available * (tail_ratio or 0.7)), true)
  local head = take(text, available - vim.fn.strdisplaywidth(tail), false)
  return head .. '…' .. tail
end

-- Truncate paths from the left by whole segments where possible so the leaf
-- directory stays readable (`…/callback/` instead of `drive_…callback/`).
function M.truncate_dir(path, width)
  width = math.max(0, width)
  local label = path .. '/'
  if vim.fn.strdisplaywidth(label) <= width then return label end
  local segments = vim.split(path, '/', { plain = true })
  if #segments > 1 then
    local suffix = segments[#segments] .. '/'
    for i = #segments - 1, 2, -1 do
      local candidate = '…/' .. table.concat(segments, '/', i) .. '/'
      if vim.fn.strdisplaywidth(candidate) <= width then return candidate end
    end
    local leaf_candidate = '…/' .. suffix
    if vim.fn.strdisplaywidth(leaf_candidate) <= width then return leaf_candidate end
    local prefix_w = vim.fn.strdisplaywidth('…/')
    if width > prefix_w + 2 then return '…/' .. M.truncate(suffix, width - prefix_w, 0.75) end
  end
  return M.truncate(label, width, 0.75)
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

local function common_dir_prefix(names)
  if #names < 2 then return nil end
  local shared
  for _, name in ipairs(names) do
    if name == '.' then return nil end
    local parts = vim.split(name, '/', { plain = true })
    if not shared then
      shared = parts
    else
      local limit = math.min(#shared, #parts)
      local matched = 0
      for i = 1, limit do
        if shared[i] ~= parts[i] then break end
        matched = i
      end
      if matched == 0 then return nil end
      for i = #shared, matched + 1, -1 do
        shared[i] = nil
      end
    end
  end
  if not shared or #shared == 0 then return nil end
  local prefix = table.concat(shared, '/')
  -- Keep at least a non-empty relative label on every group; if one group IS
  -- the shared directory itself, step up one level when possible.
  for _, name in ipairs(names) do
    if name == prefix then
      if #shared == 1 then return nil end
      shared[#shared] = nil
      return table.concat(shared, '/')
    end
  end
  return prefix
end

local function display_dir_name(name, root_prefix)
  if not root_prefix then return name end
  if name:sub(1, #root_prefix + 1) == root_prefix .. '/' then return name:sub(#root_prefix + 2) end
  return name
end

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
  return groups, names, common_dir_prefix(names)
end

function M.preferred_width(files, available)
  local groups, names, root_prefix = group_files(files)
  local width = 18
  local directory_padding = vim.fn.strdisplaywidth('▾ /  ')
  local file_padding = vim.fn.strdisplaywidth('  M ') + 1
  for _, name in ipairs(names) do
    local dir_label = vim.fn.strtrans(display_dir_name(name, root_prefix))
    width = math.max(width, vim.fn.strdisplaywidth(dir_label) + #tostring(#groups[name]) + directory_padding)
    for _, entry in ipairs(groups[name]) do
      local filename = vim.fn.strtrans(vim.fn.fnamemodify(entry.path, ':t'))
      width = math.max(width, vim.fn.strdisplaywidth(filename) + file_padding)
    end
  end
  -- Leave at least 80% of the original window for code, even on small screens.
  return math.max(1, math.min(width, 28, math.floor(available * 0.2)))
end

function M.layout(files, width)
  local groups, names, root_prefix = group_files(files)
  local result = { lines = {}, rows = {}, groups = {}, line_to_file_index = {}, common_prefix = root_prefix }

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
    local entries = groups[name]
    local count = tostring(#entries)
    local prefix = '▾ '
    local dir_label = vim.fn.strtrans(display_dir_name(name, root_prefix))
    local label = M.truncate_dir(dir_label, width - vim.fn.strdisplaywidth(prefix) - #count - 2)
    local left = prefix .. label
    local padding = string.rep(' ', math.max(1, width - vim.fn.strdisplaywidth(left) - #count - 1))
    local line = left .. padding .. count .. ' '
    local count_col = #left + #padding
    local group = { path = name, first = #result.lines + 1 }
    local leaf_dir = vim.fn.fnamemodify(name, ':t')
    add(line, {
      path = name,
      highlights = {
        { 0, #left, 'BigDiffDir' },
        { count_col, count_col + #count, 'BigDiffTreeCount' },
      },
    })

    for _, entry in ipairs(entries) do
      local indent = '  '
      local file_prefix = indent .. entry.status .. ' '
      local filename = vim.fn.strtrans(vim.fn.fnamemodify(entry.path, ':t'))
      -- When filenames repeat the folder name (`notification_handler.go` in
      -- `notification/`), keep even more of the suffix so the distinguishing
      -- part survives narrow widths.
      local tail_ratio = (leaf_dir ~= '' and leaf_dir ~= '.' and filename:sub(1, #leaf_dir + 1) == leaf_dir .. '_')
          and 0.8
        or 0.7
      local display = M.truncate(filename, width - vim.fn.strdisplaywidth(file_prefix), tail_ratio)
      add(file_prefix .. display, {
        path = entry.path,
        file_index = entry.index,
        filename_col = #file_prefix,
        highlights = {
          { #indent, #indent + #entry.status, status_highlights[entry.status] or 'BigDiffTreeModified' },
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
