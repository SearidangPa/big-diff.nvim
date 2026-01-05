local M = {}

local ctx = require 'butterfly.utils_picker_context'

local EXCLUDED_FILETYPES = { 'help', 'oil' }

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

local EXTRA_HIGHLIGHTS = {
  ['%f[%w]function%f[%W]'] = '@keyword.function',
  ['%f[%w]function%f[%W]%s+[_%a][_%w]*'] = '@function',
  ['%f[%w]function%f[%W]%s+[_%a][_%w]*%.[_%a][_%w]*'] = '@function',
  ['%f[%w]function%f[%W]%s+[_%a][_%w]*:[_%a][_%w]*'] = '@function.method',
}

local function format_item(item, _)
  return ctx.format_item(item, {
    header_hl_group = 'JumpFzfFilename',
    extra_highlights = EXTRA_HIGHLIGHTS,
  })
end

---@param opts? { current_buf_only?: boolean }
function M.pick(opts)
  opts = opts or {}

  vim.api.nvim_set_hl(0, 'JumpFzfFilename', { fg = '#AED28C' })

  local cwd = vim.fn.getcwd()
  local list = vim.fn.getjumplist()[1] or {}
  local cur_buf = opts.current_buf_only and vim.api.nvim_get_current_buf() or nil

  local by_file = {}
  local file_order = {}

  for _, j in ipairs(list) do
    local bufnr = j.bufnr
    local line = tonumber(j.lnum) or 1
    local col = tonumber(j.col) or 1

    if not cur_buf or bufnr == cur_buf then
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
  end

  local items = {}

  for _, file in ipairs(file_order) do
    local jumps = by_file[file]

    local ft, lang = ctx.resolve_ft_and_lang(file)

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
      local scope = ctx.get_scope_at_line(file, j.line, { excluded_filetypes = EXCLUDED_FILETYPES })

      -- Prefer de-duping by scope name ("per function"), since jumplist entries
      -- often land multiple times within the same function/method.
      local key = scope and scope.name or ('line:' .. tostring(j.line) .. ':' .. tostring(j.col))

      if not seen[key] then
        seen[key] = true

        local context_line = nil
        if not scope then
          context_line = ctx.get_context_line(file, j.line, {
            filter_punctuation = true,
            excluded_filetypes = EXCLUDED_FILETYPES,
          })
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
        if item.line then
          vim.api.nvim_win_set_cursor(0, { item.line, (item.col or 1) - 1 })
        end
      end
    end,
  }
end

vim.keymap.set('n', '<leader>jj', function()
  require('butterfly.jumplist_fzf').pick()
end, { desc = 'Jumplist (cwd)' })

vim.keymap.set('n', '<localleader>j', function()
  require('butterfly.jumplist_fzf').pick { current_buf_only = true }
end, { desc = 'Jumplist (buffer)' })

return M
