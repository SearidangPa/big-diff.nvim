local M = {}

local DEFAULT_SCOPE_NODE_TYPES = { 'function_declaration', 'function_definition', 'method_declaration' }

local scope_node_types_by_filetype = {
  lua = { 'function_declaration', 'function_definition', 'local_function' },
  go = { 'function_declaration', 'method_declaration', 'type_spec' },
  fish = { 'function_definition' },
  zig = { 'function_declaration' },
}

---@param abs_path string
---@return integer
local function load_file_buffer(abs_path)
  local bufnr = vim.fn.bufnr(abs_path)

  if bufnr == -1 then
    if not vim.loop.fs_stat(abs_path) then
      return -1
    end

    bufnr = vim.fn.bufadd(abs_path)
  end

  if vim.fn.bufloaded(bufnr) == 0 then
    vim.fn.bufload(bufnr)
  end

  return bufnr
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

---@param filepath string
---@param line number
---@return ScopeInfo?
local function get_scope_at_line(filepath, line)
  local abs_path = vim.fn.fnamemodify(filepath, ':p')
  local bufnr = load_file_buffer(abs_path)

  if bufnr == -1 then
    return nil
  end

  if vim.bo[bufnr].filetype == '' then
    local detected = vim.filetype.match { filename = abs_path }
    if detected and detected ~= '' then
      vim.bo[bufnr].filetype = detected
    end
  end

  local ft = vim.bo[bufnr].filetype
  if ft == 'help' or ft == 'oil' then
    return nil
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local row = math.max(0, line - 1)
  local root = tree:root()
  local node = root:named_descendant_for_range(row, 0, row, 0)

  local scope_node_types = scope_node_types_by_filetype[ft] or DEFAULT_SCOPE_NODE_TYPES

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

          return { name = name, signature = signature, kind = 'function' }
        end
      end
    end

    node = node:parent()
  end

  return nil
end

---@param filepath string
---@param line number
---@return string?
local function get_context_line(filepath, line)
  local abs_path = vim.fn.fnamemodify(filepath, ':p')
  local bufnr = load_file_buffer(abs_path)

  if bufnr == -1 then
    return nil
  end

  if vim.bo[bufnr].filetype == 'help' or vim.bo[bufnr].filetype == 'oil' then
    return nil
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
        return trimmed
      end
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

---@param abs_path string
---@param cwd string
---@return boolean
local function is_under_cwd(abs_path, cwd)
  if not abs_path or abs_path == '' or not cwd or cwd == '' then
    return false
  end

  local abs = vim.fn.fnamemodify(abs_path, ':p')
  local root = vim.fn.fnamemodify(cwd, ':p')

  abs = abs:gsub('/+$', '')
  root = root:gsub('/+$', '')

  if abs == root then
    return true
  end

  return abs:sub(1, #root + 1) == (root .. '/')
end

---@param bufnr integer
---@param abs_path string
---@return boolean
local function is_excluded(bufnr, abs_path)
  if not abs_path or abs_path == '' then
    return true
  end

  if abs_path:match '^%a+://' then
    return true
  end

  if bufnr and bufnr ~= -1 then
    local ft = vim.bo[bufnr].filetype
    if ft == 'oil' or ft == 'help' then
      return true
    end
  end

  return false
end

---@param abs_path string
---@return string
local function shorten_path(abs_path)
  local rel = vim.fn.fnamemodify(abs_path, ':~:.')
  if rel == abs_path then
    return vim.fn.fnamemodify(abs_path, ':~')
  end
  return rel
end

local tree_icons = { vertical = '│ ', middle = '├╴', last = '└╴' }

---@param filepath string
---@return string?, string?
local function resolve_ft_and_lang(filepath)
  local abs = vim.fn.fnamemodify(filepath, ':p')
  local ft = vim.filetype.match { filename = abs }

  if not ft or ft == '' then
    local bufnr = vim.fn.bufnr(abs)
    if bufnr ~= -1 then
      ft = vim.bo[bufnr].filetype
    end
  end

  local lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
  return ft, lang
end

---@param item table
---@return snacks.picker.Highlight[]
local function format_item(item, _)
  local ret = {} ---@type snacks.picker.Highlight[]

  if item.is_header then
    local filename = vim.fn.fnamemodify(item.file, ':t')
    ret[#ret + 1] = { filename, 'JumpFzfFilename' }
    return ret
  end

  local icon = item.last and tree_icons.last or tree_icons.middle
  ret[#ret + 1] = { icon, 'SnacksPickerTree' }
  ret[#ret + 1] = { ' ' }

  local lang = item.lang
  local ft = item.ft
  local abs_path = vim.fn.fnamemodify(item.file, ':p')
  local bufnr = load_file_buffer(abs_path)

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
    -- Manual fallback for keywords / identifiers TreeSitter may miss on truncated fragments
    local extra = {
      ['%f[%w]function%f[%W]'] = '@keyword.function',
    }

    if (lang == 'lua' or ft == 'lua') and signature then
      -- Highlight the identifier following `function` for common Lua forms:
      --   local function name(...)
      --   function name(...)
      --   function M.name(...)
      --   function M:name(...)
      extra['%f[%w]function%f[%W]%s+[_%a][_%w]*'] = '@function'
      extra['%f[%w]function%f[%W]%s+[_%a][_%w]*%.[_%a][_%w]*'] = '@function'
      extra['%f[%w]function%f[%W]%s+[_%a][_%w]*:[_%a][_%w]*'] = '@function.method'
    end

    Snacks.picker.highlight.highlight(ret, extra)
    return ret
  end

  if bufnr == -1 then
    ret[#ret + 1] = { '(file level)', 'Comment' }
    return ret
  end

  local line_content = item.context_line or get_context_line(item.file, item.line)
  if not line_content then
    return {}
  end

  Snacks.picker.highlight.format(item, line_content, ret, { lang = lang, ft = ft })
  return ret
end

---@param opts? { cwd_only?: boolean }
function M.pick(opts)
  opts = opts or {}

  vim.api.nvim_set_hl(0, 'JumpFzfFilename', { fg = '#AED28C' })

  local cwd = vim.fn.getcwd()
  local list = vim.fn.getjumplist()[1] or {}

  local by_file = {}
  local file_order = {}

  for _, j in ipairs(list) do
    local bufnr = j.bufnr
    local line = tonumber(j.lnum) or 1
    local col = tonumber(j.col) or 1

    local name = ''
    if bufnr and bufnr ~= 0 then
      name = vim.fn.bufname(bufnr)
    end

    if name and name ~= '' then
      local abs = vim.fn.fnamemodify(name, ':p')

      local stat = vim.loop.fs_stat(abs)
      local is_file = stat and stat.type == 'file'

      if is_file and not is_excluded(bufnr, abs) and is_under_cwd(abs, cwd) then
        if not by_file[abs] then
          by_file[abs] = {}
          table.insert(file_order, abs)
        end
        table.insert(by_file[abs], { bufnr = bufnr, line = line, col = col })
      end
    end
  end

  local items = {}

  for _, file in ipairs(file_order) do
    local jumps = by_file[file]

    local ft, lang = resolve_ft_and_lang(file)

    local file_item = {
      file = file,
      is_header = true,
      text = vim.fn.fnamemodify(file, ':t'),
      ft = ft,
      lang = lang,
    }

    local seen = {}
    local children = {}

    for _, j in ipairs(jumps) do
      local scope = get_scope_at_line(file, j.line)

      -- Prefer de-duping by scope name ("per function"), since jumplist entries
      -- often land multiple times within the same function/method.
      local key = scope and scope.name or ('line:' .. tostring(j.line) .. ':' .. tostring(j.col))

      if not seen[key] then
        seen[key] = true

        local context_line = nil
        if not scope then
          context_line = get_context_line(file, j.line)
        end

        local search_text = scope and scope.name or context_line or key

        table.insert(children, {
          file = file,
          line = j.line,
          col = j.col,
          scope = scope,
          context_line = context_line,
          ft = ft,
          lang = lang,
          text = shorten_path(file) .. ' ' .. search_text,
          parent = file_item,
        })
      end
    end

    if #children > 0 then
      table.insert(items, file_item)

      children[#children].last = true
      for _, child in ipairs(children) do
        table.insert(items, child)
      end
    end
  end

  Snacks.picker {
    title = 'Jumplist (cwd)',
    items = items,
    format = format_item,
    layout = {
      layout = {
        box = 'horizontal',
        width = vim.o.columns,
        height = 0.7,
        border = 'rounded',
        title = '{title} {live} {flags}',
        {
          box = 'vertical',
          width = vim.o.columns,
          { win = 'input', height = 1,     border = 'bottom' },
          { win = 'list',  border = 'none' },
        },
      },
    },
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.cmd('edit ' .. vim.fn.fnameescape(item.file))
      end
    end,
  }
end

vim.keymap.set('n', '<leader>j', function()
  require('butterfly.jumplist_fzf').pick()
end, { desc = 'Jumplist (cwd)' })

return M
