local M = {}

M.DEFAULT_SCOPE_NODE_TYPES = { 'function_declaration', 'function_definition', 'method_declaration' }

M.scope_node_types_by_filetype = {
  lua = { 'function_declaration', 'function_definition', 'local_function' },
  go = { 'function_declaration', 'method_declaration', 'type_spec' },
  fish = { 'function_definition' },
  zig = { 'function_declaration' },
}

M.ignored_context_node_types_by_filetype = {
  go = { 'import_declaration', 'import_spec', 'import_spec_list' },
}

M.comment_node_types = {
  'comment',
  'block_comment',
  'line_comment',
}

---@param node_type string
---@return boolean
local function is_comment_node_type(node_type)
  for _, t in ipairs(M.comment_node_types) do
    if node_type == t then
      return true
    end
  end
  return false
end

M.tree_icons = { vertical = '│ ', middle = '├╴', last = '└╴' }

---@param abs_path string
---@return integer
function M.load_file_buffer(abs_path)
  local bufnr = vim.fn.bufnr(abs_path)

  if bufnr == -1 then
    if not vim.loop.fs_stat(abs_path) then
      return -1
    end

    bufnr = vim.fn.bufadd(abs_path)
  end

  if vim.fn.bufloaded(bufnr) == 0 then
    -- Suppress autocommands during buffer load to prevent screen flashing
    local old_eventignore = vim.o.eventignore
    vim.o.eventignore = 'all'
    vim.fn.bufload(bufnr)
    vim.o.eventignore = old_eventignore
  end

  return bufnr
end

---@param filepath string
---@return string?, string?
function M.resolve_ft_and_lang(filepath)
  local abs = vim.fn.fnamemodify(filepath, ':p')
  local ft = vim.filetype.match { filename = abs }

  if not ft or ft == '' then
    local bufnr = vim.fn.bufnr(abs)
    if bufnr ~= -1 then
      ft = vim.bo[bufnr].filetype
    end
  end

  if not ft or ft == '' then
    local ext = filepath:match '%.([%w_]+)$'
    local map = { lua = 'lua', go = 'go', zig = 'zig', fish = 'fish' }
    ft = ext and map[ext] or nil
  end

  local lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
  return ft, lang
end

---@param filepath string
---@param line number
---@param opts? { check_ignored?: boolean, excluded_filetypes?: string[] }
---@return ScopeInfo?, boolean?
function M.get_scope_at_line(filepath, line, opts)
  opts = opts or {}
  local check_ignored = opts.check_ignored or false
  local excluded_filetypes = opts.excluded_filetypes or {}

  local abs_path = vim.fn.fnamemodify(filepath, ':p')
  local bufnr = M.load_file_buffer(abs_path)

  if bufnr == -1 then
    return nil, check_ignored and false or nil
  end

  if vim.bo[bufnr].filetype == '' then
    local detected = vim.filetype.match { filename = abs_path }
    if detected and detected ~= '' then
      vim.bo[bufnr].filetype = detected
    end
  end

  local ft = vim.bo[bufnr].filetype

  for _, excluded in ipairs(excluded_filetypes) do
    if ft == excluded then
      return nil, check_ignored and false or nil
    end
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil, check_ignored and false or nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil, check_ignored and false or nil
  end

  local row = math.max(0, line - 1)
  local root = tree:root()
  local node = root:named_descendant_for_range(row, 0, row, 0)

  local scope_node_types = M.scope_node_types_by_filetype[ft] or M.DEFAULT_SCOPE_NODE_TYPES

  local ignored = false

  if check_ignored then
    local function is_go_build_tag_comment(n)
      if not n or ft ~= 'go' then
        return false
      end

      if n:type() ~= 'comment' then
        return false
      end

      local text = vim.treesitter.get_node_text(n, bufnr) or ''
      return text:match '^//%s*go:build%s+.+' ~= nil or text:match '^//%s*%+build%s+.+' ~= nil
    end

    local function is_go_build_tag_blank_line(row0)
      if ft ~= 'go' or row0 < 0 then
        return false
      end

      local cur = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ''
      if not cur:match '^%s*$' then
        return false
      end

      local max_lookback = 5
      for i = 1, max_lookback do
        local r = row0 - i
        if r < 0 then
          break
        end

        local prev = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ''
        if prev:match '^%s*$' then
          -- keep scanning upward
        elseif prev:match '^//%s*go:build%s+.+' or prev:match '^//%s*%+build%s+.+' then
          return true
        else
          return false
        end
      end

      return false
    end

    local function is_ignored_context_node(n)
      if not n then
        return false
      end

      local types = M.ignored_context_node_types_by_filetype[ft]
      if not types then
        return false
      end

      local t = n:type()
      for _, ignored_type in ipairs(types) do
        if t == ignored_type then
          return true
        end
      end

      return false
    end

    local check = node
    while check do
      if is_ignored_context_node(check) or is_go_build_tag_comment(check) then
        ignored = true
        break
      end
      check = check:parent()
    end

    if not ignored and is_go_build_tag_blank_line(row) then
      ignored = true
    end
  end

  -- If on a comment node, look forward through siblings to find the nearest scope
  local function find_scope_in_siblings(start_node)
    local sibling = start_node:next_named_sibling()
    while sibling do
      local sibling_type = sibling:type()
      for _, scope_type in ipairs(scope_node_types) do
        if sibling_type == scope_type then
          local name = nil
          for child in sibling:iter_children() do
            local child_type = child:type()
            if
              child_type == 'name'
              or child_type == 'identifier'
              or child_type == 'field_identifier'
              or child_type == 'type_identifier'
              or child_type == 'dot_index_expression'
              or child_type == 'method_index_expression'
            then
              name = vim.treesitter.get_node_text(child, bufnr)
              break
            end
          end
          if name then
            local signature = vim.treesitter.get_node_text(sibling, bufnr)
            if sibling_type == 'type_spec' then
              signature = 'type ' .. signature
            end
            return { name = name, signature = signature, kind = 'function' }
          end
        end
      end
      sibling = sibling:next_named_sibling()
    end
    return nil
  end

  -- If on a blank line (node is source_file), look forward for comment or scope
  if node and node:type() == 'source_file' then
    for child in node:iter_children() do
      local child_start_row = child:range()
      if child_start_row >= row then
        if is_comment_node_type(child:type()) then
          local scope_from_sibling = find_scope_in_siblings(child)
          if scope_from_sibling then
            return scope_from_sibling, check_ignored and ignored or nil
          end
        end
        break
      end
    end
  end

  if node and is_comment_node_type(node:type()) then
    -- First try siblings at current level
    local scope_from_sibling = find_scope_in_siblings(node)
    if scope_from_sibling then
      return scope_from_sibling, check_ignored and ignored or nil
    end
    -- If no sibling scope found, also check parent's siblings (for nested comments)
    local parent = node:parent()
    if parent and is_comment_node_type(parent:type()) then
      scope_from_sibling = find_scope_in_siblings(parent)
      if scope_from_sibling then
        return scope_from_sibling, check_ignored and ignored or nil
      end
    end
  end

  while node do
    local node_type = node:type()

    for _, scope_type in ipairs(scope_node_types) do
      if node_type == scope_type then
        local name = nil

        for child in node:iter_children() do
          local child_type = child:type()
          if
            child_type == 'name'
            or child_type == 'identifier'
            or child_type == 'field_identifier'
            or child_type == 'type_identifier'
            -- Lua: `function M.pick(...)` / `function M:pick(...)`
            or child_type == 'dot_index_expression'
            or child_type == 'method_index_expression'
          then
            name = vim.treesitter.get_node_text(child, bufnr)
            break
          end
        end

        if name then
          local signature = vim.treesitter.get_node_text(node, bufnr)
          if node_type == 'type_spec' then
            signature = 'type ' .. signature
          end

          return { name = name, signature = signature, kind = 'function' }, check_ignored and ignored or nil
        end
      end
    end

    node = node:parent()
  end

  return nil, check_ignored and ignored or nil
end

---@param filepath string
---@param line number
---@param opts? { filter_punctuation?: boolean, excluded_filetypes?: string[] }
---@return string?
function M.get_context_line(filepath, line, opts)
  opts = opts or {}
  local filter_punctuation = opts.filter_punctuation or false
  local excluded_filetypes = opts.excluded_filetypes or {}

  local abs_path = vim.fn.fnamemodify(filepath, ':p')
  local bufnr = M.load_file_buffer(abs_path)

  if bufnr == -1 then
    return nil
  end

  local ft = vim.bo[bufnr].filetype
  for _, excluded in ipairs(excluded_filetypes) do
    if ft == excluded then
      return nil
    end
  end

  local total = vim.api.nvim_buf_line_count(bufnr)
  if total == 0 then
    return nil
  end

  local function find_non_empty(idx_start, num_lines, dir)
    local function get_lines(start_idx, n)
      local s = math.max(0, start_idx)
      local e = math.min(total, s + n)
      if e <= s then
        return {}
      end
      return vim.api.nvim_buf_get_lines(bufnr, s, e, false)
    end

    local lines = get_lines(idx_start, num_lines)
    if dir < 0 then
      local rev = {}
      for i = #lines, 1, -1 do
        rev[#rev + 1] = lines[i]
      end
      lines = rev
    end

    for _, l in ipairs(lines) do
      local trimmed = (l or ''):gsub('^%s+', '')
      if trimmed ~= '' then
        if filter_punctuation and trimmed:match '^[%p%s]+$' then
          goto continue
        end
        return trimmed
      end
      ::continue::
    end

    return nil
  end

  local start_line = tonumber(line) or 1
  local line_idx = math.max(0, math.min(total - 1, start_line - 1))

  local line_content = find_non_empty(line_idx, 10, 1)

  if not line_content then
    local back_lines = 10
    local back_start = math.max(0, line_idx - back_lines)
    if back_start < line_idx then
      line_content = find_non_empty(back_start, line_idx - back_start, -1)
    end
  end

  return line_content
end

---@param item table
---@param opts { header_hl_group: string, extra_highlights?: table }
---@return snacks.picker.Highlight[]
function M.format_item(item, opts)
  local ret = {} ---@type snacks.picker.Highlight[]

  if item.is_header then
    local filename = vim.fn.fnamemodify(item.file, ':t')
    ret[#ret + 1] = { filename, opts.header_hl_group }
    return ret
  end

  local icon = item.last and M.tree_icons.last or M.tree_icons.middle
  ret[#ret + 1] = { icon, 'SnacksPickerTree' }
  ret[#ret + 1] = { ' ' }

  local lang = item.lang
  local ft = item.ft
  local abs_path = vim.fn.fnamemodify(item.file, ':p')
  local bufnr = M.load_file_buffer(abs_path)

  if (not ft or ft == '') and bufnr ~= -1 then
    ft = vim.bo[bufnr].filetype
    if ft == '' then
      local detected = vim.filetype.match { filename = abs_path, buf = bufnr }
      if detected then
        ft = detected
        vim.bo[bufnr].filetype = ft
      end
    end
  end

  if not lang or lang == '' then
    lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
  end

  if item.scope and item.scope.signature then
    local signature = item.scope.signature:match '^[^\n]*' or item.scope.signature
    signature = signature:gsub('^%s+', '')
    Snacks.picker.highlight.format(item, signature, ret, { lang = lang, ft = ft })

    if opts.extra_highlights then
      Snacks.picker.highlight.highlight(ret, opts.extra_highlights)
    end

    return ret
  end

  if bufnr == -1 then
    ret[#ret + 1] = { '(file level)', 'Comment' }
    return ret
  end

  local line_content = item.context_line or M.get_context_line(item.file, item.line)

  if not line_content then
    return {}
  end

  Snacks.picker.highlight.format(item, line_content, ret, { lang = lang, ft = ft })

  if opts.extra_highlights then
    Snacks.picker.highlight.highlight(ret, opts.extra_highlights)
  end

  return ret
end

return M
