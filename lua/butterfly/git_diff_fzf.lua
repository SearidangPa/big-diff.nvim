local M = {}

local ctx = require 'butterfly.utils_picker_context'

---@param base? string
---@param this_file? string
---@param callback fun(hunks: table[])
local function get_diff_hunks(base, this_file, callback)
  base = base or 'HEAD'

  local cmd = { 'git', 'diff', base, '--unified=0' }
  if this_file and this_file ~= '' then
    cmd[#cmd + 1] = '--'
    cmd[#cmd + 1] = this_file
  end

  vim.system(cmd, { text = true }, function(obj)
    local hunks = {}
    local output = obj.stdout or ''
    local current_file = nil

    for line in output:gmatch '[^\n]+' do
      local file = line:match '^%+%+%+ b/(.+)$'
      if file then
        current_file = file
      elseif current_file then
        local start_line, count = line:match '^@@ .* %+(%d+),?(%d*)'
        if start_line then
          count = tonumber(count) or 1
          table.insert(hunks, { file = current_file, line = tonumber(start_line), count = count })
        end
      end
    end

    vim.schedule(function()
      callback(hunks)
    end)
  end)
end

local function format_item(item, _)
  return ctx.format_item(item, { header_hl_group = 'GitDiffFzfFilename' })
end

---@param opts? { base?: string, file?: string }
function M.pick(opts)
  opts = opts or {}
  local base = opts.base or 'HEAD'

  local file_name_hl
  if vim.o.background == 'dark' then
    file_name_hl = '#AED28C'
  else
    file_name_hl = '#5E8C4A'
  end


  vim.api.nvim_set_hl(0, 'GitDiffFzfFilename', { fg = file_name_hl, bold = true })

  get_diff_hunks(base, opts.file, function(hunks)
    local by_file = {}
    local file_order = {}

    for _, hunk in ipairs(hunks) do
      if not by_file[hunk.file] then
        by_file[hunk.file] = {}
        table.insert(file_order, hunk.file)
      end
      table.insert(by_file[hunk.file], hunk)
    end

    local items = {}

    for _, file in ipairs(file_order) do
      local file_hunks = by_file[file]
      local ft, lang = ctx.resolve_ft_and_lang(file)

      local file_item = {
        file = file,
        line = file_hunks[1].line,
        is_header = true,
        text = file,
        ft = ft,
        lang = lang,
      }
      -- Insert header only if we have at least one non-import child.
      -- We delay inserting until after filtering.

      local seen = {}
      local children = {}

      local non_import_children = 0

      for _, hunk in ipairs(file_hunks) do
        local scope, ignored = ctx.get_scope_at_line(hunk.file, hunk.line, { check_ignored = true })

        if not ignored then
          if not ft or ft == '' then
            local b = vim.fn.bufnr(vim.fn.fnamemodify(hunk.file, ':p'))
            if b ~= -1 then
              ft = vim.bo[b].filetype
              lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
            end
          end

          local key = scope and scope.name or ('line:' .. tostring(hunk.line))

          if not seen[key] then
            seen[key] = true
            non_import_children = non_import_children + 1

            local context_line = nil
            if not scope then
              context_line = ctx.get_context_line(hunk.file, hunk.line)
            end

            local search_text = scope and scope.name or context_line or key

            table.insert(children, {
              file = hunk.file,
              line = hunk.line,
              count = hunk.count,
              scope = scope,
              context_line = context_line,
              ft = ft,
              lang = lang,
              text = file .. ' ' .. search_text,
              parent = file_item,
            })
          end
        end
      end

      if non_import_children > 0 then
        table.insert(items, file_item)

        if #children > 0 then
          children[#children].last = true
        end

        for _, child in ipairs(children) do
          table.insert(items, child)
        end
      end
    end

    Snacks.picker {
      title = 'Git Diff: ' .. base,
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
          local line_count = vim.api.nvim_buf_line_count(0)
          local target_line = math.max(1, math.min(item.line, line_count))
          vim.api.nvim_win_set_cursor(0, { target_line, 0 })
        end
      end,
    }
  end)
end

vim.keymap.set('n', '<leader>gg', function()
  require('config.util_git').get_default_base_branch_async(function(branch)
    require('butterfly.git_diff_fzf').pick { base = branch }
  end)
end, { desc = 'Git Diff w/ context (vs default branch)' })

vim.keymap.set('n', '<leader>gf', function()
  local file = vim.fn.expand '%'
  if not file or file == '' then
    vim.notify('No file in current buffer', vim.log.levels.WARN)
    return
  end

  require('config.util_git').get_default_base_branch_async(function(branch)
    require('butterfly.git_diff_fzf').pick { base = branch, file = file }
  end)
end, { desc = 'Git Diff current file with default branch' })

vim.keymap.set('n', '<leader>ge', function()
  require('butterfly.git_diff_fzf').pick { base = 'HEAD' }
end, { desc = 'Git Diff w/ context (vs HEAD)' })

return M
