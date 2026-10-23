---Fancy diff renderer.
---
---Turns a parsed diff into `snacks.picker.Highlight[][]` rows: a block header
---per file, a dual (old/new) line-number gutter, per-line add/delete/context
---highlights and optional annotations drawn onto a given file/side/line.
local M = {}

local diff_parse = require('big-diff.nvim.patch')

local CONFLICT_MARKERS = { '<<<<<<<', '=======', '>>>>>>>', '|||||||' }

---@class BigDiffAnnotation
---@field file string
---@field side "left"|"right"
---@field line number
---@field text snacks.picker.Highlight[][]

---@class BigDiffRenderOpts
---@field block_header? boolean render file metadata above the hunks
---@field max_hunk_lines? number only render the last N lines of a hunk
---@field hunk_header? boolean|"context" render the full hunk header, or only its context
---@field annotations? BigDiffAnnotation[]

---@return snacks.picker.highlight
local function highlight_util() return Snacks.picker.highlight end

---@param ... string
---@return table
local function line_nr_hl(...)
  local groups = vim.list_extend({ ... }, { 'NormalFloat', 'Normal' })
  local fg = Snacks.util.color(vim.deepcopy(groups))
  local bg = Snacks.util.color(vim.deepcopy(groups), 'bg')
  bg = bg or (vim.o.background == 'dark' and '#1e1e1e' or '#f5f5f5')
  fg = fg or (vim.o.background == 'dark' and '#f5f5f5' or '#1e1e1e')
  return { fg = fg, bg = Snacks.util.blend(fg, bg, 0.1) }
end

---Defines the highlight groups used by the renderer. Safe to call again after
---a colorscheme change.
function M.set_hl()
  Snacks.util.set_hl({
    DiffHeader = 'DiagnosticVirtualTextInfo',
    DiffAdd = 'DiffAdd',
    DiffDelete = 'DiffDelete',
    DiffContext = 'DiffChange',
    DiffConflict = 'DiagnosticVirtualTextWarn',
    DiffLabel = '@property',
    DiffAddLineNr = line_nr_hl('DiffAdd'),
    DiffDeleteLineNr = line_nr_hl('DiffDelete'),
    DiffContextLineNr = line_nr_hl('DiffChange'),
    DiffConflictLineNr = line_nr_hl('DiagnosticVirtualTextWarn'),
    BadgeAdd = 'DiagnosticOk',
    BadgeDelete = 'DiagnosticError',
    BadgeChange = 'DiagnosticWarn',
    BadgeInfo = 'DiagnosticHint',
  }, { prefix = 'BigDiff', default = true, managed = false })
end

---Short status badges for a block, e.g. `new`, `deleted`, `renamed`.
---@param block BigDiffBlock
---@return snacks.picker.Highlight[]
function M.badges(block)
  ---@type snacks.picker.Highlight[]
  local badges = {}

  local function add(text, hl) badges[#badges + 1] = { text, hl } end

  if block.untracked then
    add('untracked', 'BigDiffBadgeAdd')
  elseif block.new then
    add('new', 'BigDiffBadgeAdd')
  elseif block.delete then
    add('deleted', 'BigDiffBadgeDelete')
  end

  if block.rename then
    add('renamed', 'BigDiffBadgeChange')
  elseif block.copy then
    add('copied', 'BigDiffBadgeChange')
  end

  if block.mode and block.mode.from and block.mode.to then
    add(('mode %s → %s'):format(block.mode.from, block.mode.to), 'BigDiffBadgeChange')
  end

  if block.binary then add('binary', 'BigDiffBadgeInfo') end

  if block.unmerged then add('conflict', 'BigDiffBadgeDelete') end

  if block.staged then add('staged', 'BigDiffBadgeInfo') end

  return badges
end

---@param block BigDiffBlock
---@return snacks.picker.Highlight[][]
function M.format_block_header(block)
  local H = highlight_util()
  ---@type snacks.picker.Highlight[][]
  local rows = {}

  rows[#rows + 1] = H.add_eol({}, 'BigDiffDiffHeader')

  local icon, icon_hl = Snacks.util.icon(block.file)
  ---@type snacks.picker.Highlight[]
  local row = {}
  row[#row + 1] = { '  ' }
  -- Overlay keeps markdown renderers from eating the leading spaces.
  row[#row + 1] = {
    col = 0,
    virt_text = { { '  ', 'BigDiffDiffHeader' } },
    virt_text_pos = 'overlay',
  }
  row[#row + 1] = { icon, icon_hl, inline = true }
  row[#row + 1] = { ' ' }

  if block.rename and block.rename.from and block.rename.to then
    row[#row + 1] = { block.rename.from }
    row[#row + 1] = { ' → ', 'SnacksPickerDelim' }
    row[#row + 1] = { block.rename.to }
  elseif block.copy and block.copy.from and block.copy.to then
    row[#row + 1] = { block.copy.from }
    row[#row + 1] = { ' → ', 'SnacksPickerDelim' }
    row[#row + 1] = { block.copy.to }
  else
    row[#row + 1] = { block.file }
  end

  H.insert_hl(row, 'BigDiffDiffHeader')

  for _, badge in ipairs(M.badges(block)) do
    row[#row + 1] = { '  ' }
    row[#row + 1] = { badge[1], badge[2] }
  end

  H.add_eol(row, 'BigDiffDiffHeader')
  rows[#rows + 1] = row

  rows[#rows + 1] = H.add_eol({}, 'BigDiffDiffHeader')

  if block.binary and #block.hunks == 0 then rows[#rows + 1] = { { '  binary file not shown', 'Comment' } } end

  return rows
end

---Splits a hunk body into prefixes, code lines and conflict markers, and
---pre-renders the code with treesitter highlights.
---@param block BigDiffBlock
---@param hunk BigDiffHunk
local function parse_hunk(block, hunk)
  local H = highlight_util()
  local body = vim.list_slice(hunk.diff, 2)

  ---@type BigDiffPos[]
  local versions = { hunk.left }
  vim.list_extend(versions, hunk.parents or {})
  versions[#versions + 1] = hunk.right
  while #versions < 2 do
    versions[#versions + 1] = { line = hunk.line, count = 0 }
  end
  local unmerged = #versions > 2

  while #body > 0 and body[#body]:match('^%s*$') do
    table.remove(body)
  end

  local lines, prefixes, conflict_markers = {}, {}, {}
  for index, text in ipairs(body) do
    prefixes[#prefixes + 1] = text:sub(1, #versions - 1)
    local code = text:sub(#versions)
    if unmerged and vim.tbl_contains(CONFLICT_MARKERS, code:match('^%s*(%S+)')) then
      conflict_markers[index] = code
      code = ''
    end
    lines[#lines + 1] = code
  end

  -- The hunk context is prepended so treesitter sees the enclosing scope.
  table.insert(lines, 1, hunk.context or '')
  local filetype = vim.filetype.match({
    filename = block.file,
    contents = lines,
  }) or ''
  local text = H.get_virtual_lines(table.concat(lines, '\n'), {
    ft = filetype,
  })
  local context = table.remove(text, 1)
  table.remove(lines, 1)

  return {
    len = #body,
    versions = versions,
    lines = lines,
    text = text,
    prefixes = prefixes,
    conflict_markers = conflict_markers,
    context = context,
    unmerged = unmerged,
  }
end

---Line number on each side for every row of the hunk.
---@param parsed table
local function build_index(parsed)
  local versions = parsed.versions
  ---@type table<number, table<number, number>>|{ max: number }
  local index = {}
  local counters = {}
  for position, pos in ipairs(versions) do
    counters[position] = (pos.line or 1) - 1
  end

  local max = 0
  for row = 1, parsed.len do
    local prefix = parsed.prefixes[row]
    index[row] = {}

    if not parsed.conflict_markers[row] then
      for side = 1, #versions - 1 do
        local char = prefix:sub(side, side)
        if char == ' ' or char == '-' then
          counters[side] = counters[side] + 1
          index[row][side] = counters[side]
          max = math.max(max, #tostring(counters[side]))
        end
      end
    end

    -- The right side advances unless every side deleted the line.
    local on_right = false
    for side = 1, #prefix do
      if prefix:sub(side, side) ~= '-' then
        on_right = true
        break
      end
    end
    if on_right then
      local last = #counters
      counters[last] = counters[last] + 1
      index[row][last] = counters[last]
      max = math.max(max, #tostring(counters[last]))
    end
  end

  index.max = max
  return index
end

---@param hunk BigDiffHunk
---@return snacks.picker.Highlight[][]
local function format_hunk_header(hunk, mode)
  local context = hunk.context
  if mode == 'context' then
    if not context or context == '' then return {} end
  else
    context = hunk.diff[1] or '@@'
  end

  local H = highlight_util()
  local row = {
    { ' ' },
    { context, 'BigDiffDiffHeader' },
  }
  H.add_eol(row, 'BigDiffDiffHeader')
  return { row }
end

---@param annotation snacks.picker.Highlight[][]
---@param ctx { indent: snacks.picker.Highlight[], indent_width: number, hl: string }
---@return snacks.picker.Highlight[][]
local function format_annotation(annotation, ctx)
  local H = highlight_util()
  ---@type snacks.picker.Highlight[][]
  local rows = {}

  local width = 0
  for _, line in ipairs(annotation) do
    width = math.max(width, H.offset(line, { char_idx = true }))
  end
  width = math.max(width, 50)

  local function empty_row()
    local row = vim.deepcopy(ctx.indent)
    vim.list_extend(row, H.indent({}, ctx.indent_width + 2, ctx.hl))
    H.add_eol(row, ctx.hl)
    return row
  end

  local function border(left, fill, right)
    local row = vim.deepcopy(ctx.indent)
    vim.list_extend(row, H.indent({}, ctx.indent_width + 2, ctx.hl))
    H.extend(row, {
      { left .. string.rep(fill, width + 2) .. right, 'FloatBorder' },
    })
    H.add_eol(row, ctx.hl)
    return row
  end

  rows[#rows + 1] = empty_row()
  rows[#rows + 1] = border('┌', '─', '┐')
  for _, line in ipairs(annotation) do
    local row = vim.deepcopy(ctx.indent)
    vim.list_extend(row, H.indent({}, ctx.indent_width + 2, ctx.hl))
    H.extend(row, { { '│ ', 'FloatBorder' } })
    H.extend(row, vim.deepcopy(line))
    -- Closing border, placed at a fixed window column so ragged
    -- annotation lines still line up.
    row[#row + 1] = {
      col = 0,
      virt_text = { { '│', 'FloatBorder' } },
      virt_text_pos = 'overlay',
      virt_text_win_col = ctx.indent_width + width + 5,
      virt_text_repeat_linebreak = true,
    }
    H.add_eol(row, ctx.hl)
    rows[#rows + 1] = row
  end
  rows[#rows + 1] = border('└', '─', '┘')
  rows[#rows + 1] = empty_row()

  return rows
end

---@param block BigDiffBlock
---@param hunk BigDiffHunk
---@param opts BigDiffRenderOpts
---@return snacks.picker.Highlight[][]
function M.format_hunk(block, hunk, opts)
  local H = highlight_util()
  local align = Snacks.picker.util.align
  ---@type snacks.picker.Highlight[][]
  local rows = {}

  local parsed = parse_hunk(block, hunk)
  local index = build_index(parsed)

  ---@type table<string, snacks.picker.Highlight[][]>
  local annotations = {}
  for _, annotation in ipairs(opts.annotations or {}) do
    if annotation.file == block.file then
      local key = ('%s:%d'):format(annotation.side, annotation.line)
      annotations[key] = annotation.text
    end
  end

  if opts.hunk_header ~= false then vim.list_extend(rows, format_hunk_header(hunk, opts.hunk_header)) end

  local in_conflict = false
  for row = 1, parsed.len do
    local right_side = #parsed.versions
    local has_left = index[row][1] ~= nil
    local has_right = index[row][right_side] ~= nil
    local hl = (parsed.conflict_markers[row] and 'BigDiffDiffConflict')
      or (has_right and not has_left and 'BigDiffDiffAdd')
      or (has_left and not has_right and 'BigDiffDiffDelete')
      or 'BigDiffDiffContext'

    local prefix = parsed.prefixes[row]
    if parsed.unmerged then
      local marker = (parsed.conflict_markers[row] or ''):match('^%s*(%S+)') or ''
      local guide = '  '
      if marker == '<<<<<<<' then
        in_conflict = true
        guide = '┌╴'
      elseif marker == '>>>>>>>' then
        in_conflict = false
        guide = '└╴'
      elseif marker == '=======' or marker == '|||||||' then
        guide = '├╴'
      elseif in_conflict then
        guide = '│ '
      end
      prefix = align(guide, 2) .. prefix
    end

    local numbers = {}
    for side = 1, #parsed.versions do
      numbers[side] =
        align(tostring(index[row][side] or ''), index.max, { align = side == #parsed.versions and 'right' or 'left' })
    end
    local number_col = ' ' .. table.concat(numbers, '  ') .. ' '
    local prefix_col = ' ' .. prefix .. ' '

    ---@type snacks.picker.Highlight[]
    local line = {}

    -- Blank gutter repeated on wrapped lines.
    line[#line + 1] = {
      col = 0,
      virt_text = { { string.rep(' ', #number_col), hl .. 'LineNr' } },
      virt_text_pos = 'overlay',
      hl_mode = 'replace',
      virt_text_repeat_linebreak = true,
    }
    line[#line + 1] = {
      col = 0,
      virt_text = { { number_col, hl .. 'LineNr' } },
      virt_text_pos = 'overlay',
      hl_mode = 'replace',
    }

    local indent_ws = (parsed.conflict_markers[row] or parsed.lines[row] or ''):match('^(%s*)')
    line[#line + 1] = {
      col = #number_col,
      virt_text = {
        {
          align(prefix_col:gsub('[%-%+]', ' '), #indent_ws + #prefix_col),
          hl,
        },
      },
      virt_text_pos = 'overlay',
      hl_mode = 'replace',
      virt_text_repeat_linebreak = true,
    }
    line[#line + 1] = {
      col = #number_col,
      virt_text = { { prefix_col, hl } },
      virt_text_pos = 'overlay',
      hl_mode = 'replace',
    }

    rows[#rows + 1] = line

    local annotation = annotations['left:' .. (index[row][1] or '')]
      or annotations['right:' .. (index[row][right_side] or '')]
    if annotation then
      vim.list_extend(
        rows,
        format_annotation(annotation, {
          indent = { line[1] },
          indent_width = #number_col,
          hl = hl,
        })
      )
    end

    local code = H.indent({}, #number_col + #prefix_col)
    if parsed.conflict_markers[row] then
      code[#code + 1] = { parsed.conflict_markers[row], hl }
    else
      vim.list_extend(code, parsed.text[row] or {})
    end
    H.insert_hl(code, hl)
    H.extend(line, code)
    H.add_eol(line, hl)
  end

  if opts.max_hunk_lines and #rows > opts.max_hunk_lines then
    rows = vim.list_slice(rows, #rows - opts.max_hunk_lines + 1)
  end

  return rows
end

---@param block BigDiffBlock
---@param opts BigDiffRenderOpts
---@return snacks.picker.Highlight[][]
function M.format_block(block, opts)
  ---@type snacks.picker.Highlight[][]
  local rows = {}
  if opts.block_header ~= false then
    vim.list_extend(rows, M.format_block_header(block))
  elseif block.binary and #block.hunks == 0 then
    rows[#rows + 1] = { { '  binary file not shown', 'Comment' } }
  end
  for _, hunk in ipairs(block.hunks) do
    vim.list_extend(rows, M.format_hunk(block, hunk, opts))
  end
  return rows
end

---@param diff string|string[]|BigDiffDiff
---@param opts? BigDiffRenderOpts
---@return snacks.picker.Highlight[][]
function M.format(diff, opts)
  opts = opts or {}
  local parsed = diff_parse.get(diff)
  ---@type snacks.picker.Highlight[][]
  local rows = {}
  for _, block in ipairs(parsed.blocks) do
    vim.list_extend(rows, M.format_block(block, opts))
  end
  return rows
end

---@param buf number
---@param ns number
---@param diff string|string[]|BigDiffDiff
---@param opts? BigDiffRenderOpts
function M.render(buf, ns, diff, opts) return highlight_util().render(buf, ns, M.format(diff, opts)) end

-- Refreshed on ColorScheme by `viz.create_default_hl()`
M.set_hl()

return M
