local M = {}

---@class FileCache
---@field buffer_number integer
---@field changedtick integer
---@field filetype string
---@field treesitter_language string?
---@field parser vim.treesitter.LanguageTree?
---@field tree TSTree?
---@field root TSNode?
---@field scope_node_types string[]
---@field scope_cache table<number, { scope: ScopeInfo?, ignored: boolean }>
---@field build_tag_lines table<number, boolean>
---@field import_lines table<number, boolean>
---@field ignored_cache table<number, boolean>

---@type table<string, FileCache>
local file_cache = {}

M.DEFAULT_SCOPE_NODE_TYPES = {
  'function_declaration',
  'function_definition',
  'method_declaration',
}

M.scope_node_types_by_filetype = {
  lua = {
    'function_declaration',
    'function_definition',
    'local_function',
  },
  go = {
    'function_declaration',
    'method_declaration',
    'type_spec',
  },
  fish = { 'function_definition' },
  zig = { 'function_declaration' },
}

M.ignored_context_node_types_by_filetype = {
  go = {
    'import_declaration',
    'import_spec',
    'import_spec_list',
  },
  python = {
    'import_statement',
    'import_from_statement',
    'future_import_statement',
  },
  javascript = { 'import_statement' },
  javascriptreact = { 'import_statement' },
  typescript = { 'import_statement', 'import_alias' },
  typescriptreact = { 'import_statement', 'import_alias' },
  rust = { 'use_declaration' },
  java = { 'import_declaration' },
  c = { 'preproc_include' },
  cpp = { 'preproc_include' },
}

---Languages whose imports are plain statements without a dedicated treesitter
---node type. Patterns are anchored at column 0, so an import-looking line nested
---inside a function body is never treated as part of the import block.
M.import_line_patterns_by_filetype = {
  lua = {
    '^local%s+[%w_][%w_,%s]*=%s*require%f[%W]',
    '^local%s+[%w_][%w_,%s]*=%s*pcall%s*%(%s*require%f[%W]',
    '^require%f[%W]',
  },
  zig = {
    '^const%s+[%w_]+%s*=%s*@import%f[%W]',
  },
}

---@param filetype string
---@param line_text string
---@return boolean
local function matches_import_pattern(filetype, line_text)
  local patterns = M.import_line_patterns_by_filetype[filetype]
  if not patterns then return false end

  for _, pattern in ipairs(patterns) do
    if line_text:match(pattern) then return true end
  end

  return false
end

---Pre-compute the lines belonging to the import block (single pass at file load).
---Blank lines are included only when they sit between two import lines, so an
---import block split into groups still counts as one contiguous region.
---@param buffer_number integer
---@param filetype string
---@return table<number, boolean>
local function compute_import_lines(buffer_number, filetype)
  local lines_map = {}
  if not M.import_line_patterns_by_filetype[filetype] then return lines_map end

  local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, -1, false)

  for i, line in ipairs(lines) do
    if matches_import_pattern(filetype, line) then
      lines_map[i] = true -- 1-indexed
    end
  end

  local i = 1
  while i <= #lines do
    if not lines_map[i] and lines[i]:match('^%s*$') then
      local blank_end = i
      while blank_end < #lines and lines[blank_end + 1]:match('^%s*$') do
        blank_end = blank_end + 1
      end

      if lines_map[i - 1] and lines_map[blank_end + 1] then
        for blank = i, blank_end do
          lines_map[blank] = true
        end
      end

      i = blank_end + 1
    else
      i = i + 1
    end
  end

  return lines_map
end

M.comment_node_types = {
  'comment',
  'block_comment',
  'line_comment',
}

---@param node_type string
---@return boolean
local function is_comment_node_type(node_type)
  for _, t in ipairs(M.comment_node_types) do
    if node_type == t then return true end
  end
  return false
end

local nvim_treesitter_loaded = false

---@param buffer_number integer
---@param treesitter_language? string
---@return vim.treesitter.LanguageTree?
local function ensure_treesitter_parser(buffer_number, treesitter_language)
  if not nvim_treesitter_loaded then
    local lazy_ok, lazy = pcall(require, 'lazy')
    if lazy_ok and lazy and type(lazy.load) == 'function' then pcall(lazy.load, { plugins = { 'nvim-treesitter' } }) end

    -- If the plugin is already on the runtimepath, this will succeed; if not,
    -- we still gracefully fall back to no treesitter context.
    pcall(require, 'nvim-treesitter')
    pcall(require, 'nvim-treesitter.parsers')

    nvim_treesitter_loaded = true
  end

  local ok, parser = pcall(vim.treesitter.get_parser, buffer_number, treesitter_language)
  if ok then return parser end

  return nil
end

---Pre-compute Go build tag lines (single pass at file load)
---@param buffer_number integer
---@return table<number, boolean>
local function compute_build_tag_lines(buffer_number)
  local lines_map = {}
  local total = vim.api.nvim_buf_line_count(buffer_number)
  if total == 0 then return lines_map end

  -- Build tags are always at top of file, read first 50 lines max
  local max_scan = math.min(total, 50)
  local lines = vim.api.nvim_buf_get_lines(buffer_number, 0, max_scan, false)

  local in_build_region = false
  for i, line in ipairs(lines) do
    if line:match('^//%s*go:build%s+.+') or line:match('^//%s*%+build%s+.+') then
      lines_map[i] = true -- 1-indexed
      in_build_region = true
    elseif in_build_region then
      if line:match('^%s*$') then
        lines_map[i] = true -- Blank line after build tag
      else
        in_build_region = false
      end
    end
  end

  return lines_map
end

---@param absolute_path string
---@param buffer_number integer
---@return table
local function compute_file_cache_state(absolute_path, buffer_number)
  if vim.bo[buffer_number].filetype == '' then
    local detected = vim.filetype.match({ filename = absolute_path })
    if detected and detected ~= '' then vim.bo[buffer_number].filetype = detected end
  end

  local filetype = vim.bo[buffer_number].filetype
  local treesitter_language = filetype and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
  local scope_node_types = M.scope_node_types_by_filetype[filetype] or M.DEFAULT_SCOPE_NODE_TYPES

  local parser, tree, root
  parser = ensure_treesitter_parser(buffer_number, treesitter_language)
  if parser then
    tree = parser:parse()[1]
    root = tree and tree:root() or nil
  end

  local build_tag_lines = {}
  if filetype == 'go' then build_tag_lines = compute_build_tag_lines(buffer_number) end

  return {
    changedtick = vim.api.nvim_buf_get_changedtick(buffer_number),
    filetype = filetype,
    treesitter_language = treesitter_language,
    parser = parser,
    tree = tree,
    root = root,
    scope_node_types = scope_node_types,
    build_tag_lines = build_tag_lines,
    import_lines = compute_import_lines(buffer_number, filetype),
  }
end

---Get or create a file cache entry (parses treesitter once per file)
---@param absolute_path string
---@return FileCache?
local function get_or_create_file_cache(absolute_path)
  local existing = file_cache[absolute_path]
  if existing then
    -- If the buffer was wiped and re-created, rebuild cache.
    if not vim.api.nvim_buf_is_valid(existing.buffer_number) then
      file_cache[absolute_path] = nil
    else
      local tick = vim.api.nvim_buf_get_changedtick(existing.buffer_number)
      if tick ~= existing.changedtick then
        local buffer_number = M.load_file_buffer(absolute_path)
        if buffer_number == -1 then return nil end

        local state = compute_file_cache_state(absolute_path, buffer_number)

        existing.buffer_number = buffer_number
        existing.scope_cache = {}
        existing.ignored_cache = {}
        for k, v in pairs(state) do
          existing[k] = v
        end
      end

      return existing
    end
  end

  local buffer_number = M.load_file_buffer(absolute_path)
  if buffer_number == -1 then return nil end

  local state = compute_file_cache_state(absolute_path, buffer_number)

  local cache = { buffer_number = buffer_number, scope_cache = {}, ignored_cache = {} }
  for k, v in pairs(state) do
    cache[k] = v
  end

  file_cache[absolute_path] = cache

  return file_cache[absolute_path]
end

---Clear file cache (useful for testing or when files change)
function M.clear_file_cache() file_cache = {} end

---Whether a line is boilerplate that should not surface as a change:
---an import block entry, or a Go build tag.
---@param cache FileCache
---@param line number
---@return boolean
local function compute_ignored_at_line(cache, line)
  -- Pre-computed lookups (O(1))
  if cache.build_tag_lines[line] or cache.import_lines[line] then return true end

  local buffer_number = cache.buffer_number
  local filetype = cache.filetype
  local root = cache.root
  if not root then return false end

  local function is_go_build_tag_comment(n)
    if not n or filetype ~= 'go' then return false end
    if n:type() ~= 'comment' then return false end
    local text = vim.treesitter.get_node_text(n, buffer_number) or ''
    return text:match('^//%s*go:build%s+.+') ~= nil or text:match('^//%s*%+build%s+.+') ~= nil
  end

  local function is_ignored_context_node(n)
    if not n then return false end
    local types = M.ignored_context_node_types_by_filetype[filetype]
    if not types then return false end
    local t = n:type()
    for _, ignored_type in ipairs(types) do
      if t == ignored_type then return true end
    end
    return false
  end

  local row = math.max(0, line - 1)
  local check = root:named_descendant_for_range(row, 0, row, 0)
  while check do
    if is_ignored_context_node(check) or is_go_build_tag_comment(check) then return true end
    check = check:parent()
  end

  return false
end

---@param cache FileCache
---@param line number
---@return boolean
local function is_ignored_line_cached(cache, line)
  local cached = cache.ignored_cache[line]
  if cached == nil then
    cached = compute_ignored_at_line(cache, line)
    cache.ignored_cache[line] = cached
  end
  return cached
end

---Whether every line of a range is ignorable boilerplate. Used to keep a hunk
---that starts in the import block but spills into real code.
---@param cache FileCache?
---@param start_line number
---@param count number
---@return boolean
function M.is_ignored_range(cache, start_line, count)
  if not cache then return false end

  local last_line = start_line + math.max(count, 1) - 1
  for line = start_line, last_line do
    if not is_ignored_line_cached(cache, line) then return false end
  end

  return true
end

---Compute scope at a line using cached file state
---@param cache FileCache
---@param line number
---@param check_ignored boolean
---@return ScopeInfo?, boolean
local function compute_scope_at_line_cached(cache, line, check_ignored)
  local buffer_number = cache.buffer_number
  local root = cache.root
  local scope_node_types = cache.scope_node_types

  if not root then return nil, check_ignored and is_ignored_line_cached(cache, line) or false end

  local row = math.max(0, line - 1)
  local node = root:named_descendant_for_range(row, 0, row, 0)

  local ignored = check_ignored and is_ignored_line_cached(cache, line) or false

  -- Helper: find scope in siblings (for comment nodes)
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
              name = vim.treesitter.get_node_text(child, buffer_number)
              break
            end
          end
          if name then
            local signature = vim.treesitter.get_node_text(sibling, buffer_number)
            if sibling_type == 'type_spec' then signature = 'type ' .. signature end
            return {
              name = name,
              signature = signature,
              kind = 'function',
            }
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
          if scope_from_sibling then return scope_from_sibling, ignored end
        end
        break
      end
    end
  end

  if node and is_comment_node_type(node:type()) then
    local scope_from_sibling = find_scope_in_siblings(node)
    if scope_from_sibling then return scope_from_sibling, ignored end
    local parent = node:parent()
    if parent and is_comment_node_type(parent:type()) then
      scope_from_sibling = find_scope_in_siblings(parent)
      if scope_from_sibling then return scope_from_sibling, ignored end
    end
  end

  -- Delegate to find_enclosing_func for the walk-up-tree logic
  local find_enclosing_func = require('lib.find_enclosing_func')
  local func_ctx = find_enclosing_func.enclosing_function(buffer_number, row)
  if func_ctx then
    local sig_line = vim.api.nvim_buf_get_lines(buffer_number, func_ctx.start_row, func_ctx.start_row + 1, false)[1]
      or ''
    return {
      name = func_ctx.name,
      signature = sig_line,
      kind = 'function',
    }, ignored
  end

  return nil, ignored
end

---Batch get scopes for multiple lines in a file (uses caching)
---@param filepath string
---@param lines number[]
---@param options? { check_ignored?: boolean }
---@return table<number, { scope: ScopeInfo?, ignored: boolean }>, FileCache?
function M.batch_get_scopes(filepath, lines, options)
  options = options or {}
  local check_ignored = options.check_ignored or false

  local absolute_path = vim.fn.fnamemodify(filepath, ':p')
  local cache = get_or_create_file_cache(absolute_path)

  local results = {}

  if not cache then
    for _, line in ipairs(lines) do
      results[line] = { scope = nil, ignored = false }
    end
    return results, nil
  end

  for _, line in ipairs(lines) do
    -- Check per-line scope cache first
    if cache.scope_cache[line] then
      results[line] = cache.scope_cache[line]
    else
      -- Compute and cache
      local scope, ignored = compute_scope_at_line_cached(cache, line, check_ignored)
      cache.scope_cache[line] = { scope = scope, ignored = ignored }
      results[line] = cache.scope_cache[line]
    end
  end

  return results, cache
end

---Get file cache for a path (creates if needed)
---@param filepath string
---@return FileCache?
function M.get_file_cache(filepath)
  local absolute_path = vim.fn.fnamemodify(filepath, ':p')
  return get_or_create_file_cache(absolute_path)
end

M.tree_icons = {
  vertical = '│ ',
  middle = '├╴',
  last = '└╴',
}

---@param absolute_path string
---@return integer
function M.load_file_buffer(absolute_path)
  local buffer_number = vim.fn.bufnr(absolute_path)

  if buffer_number == -1 then
    if not vim.loop.fs_stat(absolute_path) then return -1 end

    buffer_number = vim.fn.bufadd(absolute_path)
  end

  if vim.fn.bufloaded(buffer_number) == 0 then
    -- Suppress autocommands during buffer load to prevent screen flashing
    local old_eventignore = vim.o.eventignore
    vim.o.eventignore = 'all'
    vim.fn.bufload(buffer_number)
    vim.o.eventignore = old_eventignore
  end

  return buffer_number
end

---@param filepath string
---@return string?, string?
function M.resolve_ft_and_lang(filepath)
  local abs = vim.fn.fnamemodify(filepath, ':p')
  local filetype = vim.filetype.match({ filename = abs })

  if not filetype or filetype == '' then
    local buffer_number = vim.fn.bufnr(abs)
    if buffer_number ~= -1 then filetype = vim.bo[buffer_number].filetype end
  end

  if not filetype or filetype == '' then
    local ext = filepath:match('%.([%w_]+)$')
    local map = {
      lua = 'lua',
      go = 'go',
      zig = 'zig',
      fish = 'fish',
    }
    filetype = ext and map[ext] or nil
  end

  local treesitter_language = filetype and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
  return filetype, treesitter_language
end

---@param filepath string
---@param line number
---@param options? { check_ignored?: boolean, excluded_filetypes?: string[] }
---@return ScopeInfo?, boolean?
function M.get_scope_at_line(filepath, line, options)
  options = options or {}
  local check_ignored = options.check_ignored or false
  local excluded_filetypes = options.excluded_filetypes or {}

  local absolute_path = vim.fn.fnamemodify(filepath, ':p')
  local buffer_number = M.load_file_buffer(absolute_path)

  if buffer_number == -1 then return nil, check_ignored and false or nil end

  if vim.bo[buffer_number].filetype == '' then
    local detected = vim.filetype.match({ filename = absolute_path })
    if detected and detected ~= '' then vim.bo[buffer_number].filetype = detected end
  end

  local filetype = vim.bo[buffer_number].filetype

  for _, excluded in ipairs(excluded_filetypes) do
    if filetype == excluded then return nil, check_ignored and false or nil end
  end

  local treesitter_language = filetype and (vim.treesitter.language.get_lang(filetype) or filetype) or nil

  local parser = ensure_treesitter_parser(buffer_number, treesitter_language)
  if not parser then return nil, check_ignored and false or nil end

  local tree = parser:parse()[1]
  if not tree then return nil, check_ignored and false or nil end

  local row = math.max(0, line - 1)
  local root = tree:root()
  local node = root:named_descendant_for_range(row, 0, row, 0)

  local scope_node_types = M.scope_node_types_by_filetype[filetype] or M.DEFAULT_SCOPE_NODE_TYPES

  local ignored = false

  if check_ignored then
    local cache = get_or_create_file_cache(absolute_path)
    ignored = cache ~= nil and is_ignored_line_cached(cache, line)
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
              name = vim.treesitter.get_node_text(child, buffer_number)
              break
            end
          end
          if name then
            local signature = vim.treesitter.get_node_text(sibling, buffer_number)
            if sibling_type == 'type_spec' then signature = 'type ' .. signature end
            return {
              name = name,
              signature = signature,
              kind = 'function',
            }
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
          if scope_from_sibling then return scope_from_sibling, check_ignored and ignored or nil end
        end
        break
      end
    end
  end

  if node and is_comment_node_type(node:type()) then
    -- First try siblings at current level
    local scope_from_sibling = find_scope_in_siblings(node)
    if scope_from_sibling then return scope_from_sibling, check_ignored and ignored or nil end
    -- If no sibling scope found, also check parent's siblings (for nested comments)
    local parent = node:parent()
    if parent and is_comment_node_type(parent:type()) then
      scope_from_sibling = find_scope_in_siblings(parent)
      if scope_from_sibling then return scope_from_sibling, check_ignored and ignored or nil end
    end
  end

  -- Delegate to find_enclosing_func for the walk-up-tree logic
  local find_enclosing_func = require('lib.find_enclosing_func')
  local func_ctx = find_enclosing_func.enclosing_function(buffer_number, row)
  if func_ctx then
    local sig_line = vim.api.nvim_buf_get_lines(buffer_number, func_ctx.start_row, func_ctx.start_row + 1, false)[1]
      or ''
    return {
      name = func_ctx.name,
      signature = sig_line,
      kind = 'function',
    },
      check_ignored and ignored or nil
  end

  return nil, check_ignored and ignored or nil
end

---@param filepath string
---@param line number
---@param options? { filter_punctuation?: boolean, excluded_filetypes?: string[] }
---@return string?
function M.get_context_line(filepath, line, options)
  options = options or {}
  local filter_punctuation = options.filter_punctuation or false
  local excluded_filetypes = options.excluded_filetypes or {}

  local absolute_path = vim.fn.fnamemodify(filepath, ':p')
  local buffer_number = M.load_file_buffer(absolute_path)

  if buffer_number == -1 then return nil end

  local filetype = vim.bo[buffer_number].filetype
  for _, excluded in ipairs(excluded_filetypes) do
    if filetype == excluded then return nil end
  end

  local total = vim.api.nvim_buf_line_count(buffer_number)
  if total == 0 then return nil end

  local function find_non_empty(idx_start, num_lines, dir)
    local function get_lines(start_idx, n)
      local s = math.max(0, start_idx)
      local e = math.min(total, s + n)
      if e <= s then return {} end
      return vim.api.nvim_buf_get_lines(buffer_number, s, e, false)
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
        if filter_punctuation and trimmed:match('^[%p%s]+$') then goto continue end
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
    if back_start < line_idx then line_content = find_non_empty(back_start, line_idx - back_start, -1) end
  end

  return line_content
end

---@param item table
---@param options { header_hl_group: string, extra_highlights?: table, show_filename?: boolean, show_tree?: boolean }
---@return snacks.picker.Highlight[]
function M.format_item(item, options)
  local formatted_item = {} ---@type snacks.picker.Highlight[]

  local show_filename = options.show_filename ~= false
  local show_tree = options.show_tree ~= false

  if item.is_header then
    if not show_filename then return formatted_item end
    local filename = vim.fn.fnamemodify(item.file, ':t')
    formatted_item[#formatted_item + 1] = { filename, options.header_hl_group }
    return formatted_item
  end

  if show_tree then
    local icon = item.last and M.tree_icons.last or M.tree_icons.middle
    formatted_item[#formatted_item + 1] = { icon, 'SnacksPickerTree' }
    formatted_item[#formatted_item + 1] = { ' ' }
  end

  if show_filename then
    local truncate = require('big-diff.nvim.utils_truncate').truncate_middle
    local filename = truncate(vim.fn.fnamemodify(item.file, ':t'), {
      no_truncate_max = #'cb_handler.go',
    })
    formatted_item[#formatted_item + 1] = { filename, 'Comment' }
    formatted_item[#formatted_item + 1] = { ': ', 'Comment' }
  end

  local treesitter_language = item.treesitter_language or item.lang
  local filetype = item.filetype or item.ft
  local absolute_path = vim.fn.fnamemodify(item.file, ':p')
  local buffer_number = M.load_file_buffer(absolute_path)

  if (not filetype or filetype == '') and buffer_number ~= -1 then
    filetype = vim.bo[buffer_number].filetype
    if filetype == '' then
      local detected = vim.filetype.match({
        filename = absolute_path,
        buf = buffer_number,
      })
      if detected then
        filetype = detected
        vim.bo[buffer_number].filetype = filetype
      end
    end
  end

  if not treesitter_language or treesitter_language == '' then
    treesitter_language = filetype and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
  end

  if item.scope and item.scope.signature then
    local signature = item.scope.signature:match('^[^\n]*') or item.scope.signature
    signature = signature:gsub('^%s+', '')
    Snacks.picker.highlight.format(item, signature, formatted_item, { lang = treesitter_language, ft = filetype })

    if options.extra_highlights then Snacks.picker.highlight.highlight(formatted_item, options.extra_highlights) end

    return formatted_item
  end

  if buffer_number == -1 then
    formatted_item[#formatted_item + 1] = { '(file level)', 'Comment' }
    return formatted_item
  end

  local line_content = item.context_line or M.get_context_line(item.file, item.line)

  if not line_content then
    formatted_item[#formatted_item + 1] = { '(new file)', 'Comment' }
    return formatted_item
  end

  Snacks.picker.highlight.format(item, line_content, formatted_item, { lang = treesitter_language, ft = filetype })

  if options.extra_highlights then Snacks.picker.highlight.highlight(formatted_item, options.extra_highlights) end

  return formatted_item
end

return M
