local M = {}

local ctx = require 'butterfly.utils_picker_context'

-- Branch cache for speculative execution (survives module reload via vim.g)
local function get_branch_cache()
  vim.g._butterfly_branch_cache = vim.g._butterfly_branch_cache or {}
  return vim.g._butterfly_branch_cache
end

local function is_test_path(file_path)
  return file_path:match '[^%w]integration_tests[/\\]'
    or file_path:match '[/\\]integration_tests[/\\]'
    or file_path:match '_test%.[^/\\]+$'
    or file_path:match '_spec%.lua$'
end

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

---Process hunks and display picker (core logic extracted for reuse)
---@param opts { exclude_tests?: boolean, only_tests?: boolean, file?: string }
---@param base string
---@param hunks table[]
local function process_hunks_and_show_picker(opts, base, hunks)
  local file_name_hl = vim.o.background == 'dark' and '#AED28C' or '#5E8C4A'
  vim.api.nvim_set_hl(0, 'GitDiffFzfFilename', { fg = file_name_hl, bold = true })

  local by_file = {}
  local file_order = {}

  for _, hunk in ipairs(hunks) do
    local is_test = is_test_path(hunk.file)

    if opts.only_tests and not is_test then
      goto continue
    end

    if opts.exclude_tests and is_test then
      goto continue
    end

    if not by_file[hunk.file] then
      by_file[hunk.file] = {}
      table.insert(file_order, hunk.file)
    end
    table.insert(by_file[hunk.file], hunk)

    ::continue::
  end

  local items = {}

  for _, file in ipairs(file_order) do
    local file_hunks = by_file[file]

    -- Batch: collect all line numbers for this file
    local lines = {}
    for _, hunk in ipairs(file_hunks) do
      lines[#lines + 1] = hunk.line
    end

    -- Single batch call: get all scopes + file cache (parses treesitter once)
    local scope_results, file_cache = ctx.batch_get_scopes(file, lines, { check_ignored = true })

    -- Get ft/lang from cache (already computed during batch_get_scopes)
    local ft = file_cache and file_cache.ft or nil
    local lang = file_cache and file_cache.lang or nil
    if not ft then
      ft, lang = ctx.resolve_ft_and_lang(file)
    end

    local file_item = {
      file = file,
      line = file_hunks[1].line,
      is_header = true,
      text = file,
      ft = ft,
      lang = lang,
    }

    local seen = {}
    local children = {}
    local non_import_children = 0

    for _, hunk in ipairs(file_hunks) do
      local is_new_file_hunk = hunk.line == 1 and hunk.count > 10
      local result = scope_results[hunk.line]
      local scope = result and result.scope or nil
      local ignored = result and result.ignored or false

      if is_new_file_hunk or not ignored then
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
          { win = 'input', height = 1, border = 'bottom' },
          { win = 'list', border = 'none' },
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
end

---Pick with pre-fetched hunks (used by speculative execution)
---@param opts { exclude_tests?: boolean, only_tests?: boolean, file?: string }
---@param base string
---@param hunks table[]
function M.pick_with_hunks(opts, base, hunks)
  process_hunks_and_show_picker(opts, base, hunks)
end

---@param opts? { base?: string, file?: string, exclude_tests?: boolean, only_tests?: boolean }
function M.pick(opts)
  opts = opts or {}
  local base = opts.base or 'HEAD'

  get_diff_hunks(base, opts.file, function(hunks)
    process_hunks_and_show_picker(opts, base, hunks)
  end)
end

---Speculative parallel fetch: start diff immediately while fetching branch
---@param opts { exclude_tests?: boolean, only_tests?: boolean, file?: string }
local function pick_with_speculative_fetch(opts)
  local util_git = require 'config.util_git'
  local git_root = util_git.find_git_root()
  if not git_root then
    M.pick(vim.tbl_extend('force', opts, { base = 'main' }))
    return
  end

  local cache = get_branch_cache()
  local cached_branch = cache[git_root]

  -- Fast path: branch is cached, just pick directly
  if cached_branch then
    M.pick(vim.tbl_extend('force', opts, { base = cached_branch }))
    return
  end

  -- Speculative execution: start diff with 'main' while fetching actual branch
  local speculative_branch = 'main'
  local actual_branch = nil
  local speculative_hunks = nil
  local branch_resolved = false
  local diff_resolved = false

  local function try_finalize()
    if not branch_resolved or not diff_resolved then
      return
    end

    -- Cache the branch for future calls
    cache[git_root] = actual_branch

    if actual_branch == speculative_branch then
      -- Lucky! Speculative execution was correct, use cached hunks
      M.pick_with_hunks(opts, actual_branch, speculative_hunks)
    else
      -- Branch differs, need to fetch correct diff (rare, one-time cost)
      get_diff_hunks(actual_branch, opts.file, function(hunks)
        M.pick_with_hunks(opts, actual_branch, hunks)
      end)
    end
  end

  -- Start diff fetch immediately (speculative)
  get_diff_hunks(speculative_branch, opts.file, function(hunks)
    speculative_hunks = hunks
    diff_resolved = true
    try_finalize()
  end)

  -- Fetch actual branch in parallel
  util_git.get_default_base_branch_async(function(branch)
    actual_branch = branch
    branch_resolved = true
    try_finalize()
  end)
end

vim.keymap.set('n', '<leader>gg', function()
  pick_with_speculative_fetch { exclude_tests = true }
end, { desc = 'Git Diff w/ context (vs default branch)' })

vim.keymap.set('n', '<leader>gt', function()
  pick_with_speculative_fetch { only_tests = true }
end, { desc = 'Git Diff tests only (vs default branch)' })

vim.keymap.set('n', '<leader>gf', function()
  local file = vim.fn.expand '%'
  if not file or file == '' then
    vim.notify('No file in current buffer', vim.log.levels.WARN)
    return
  end
  pick_with_speculative_fetch { file = file }
end, { desc = 'Git Diff current file with default branch' })

vim.keymap.set('n', '<leader>ge', function()
  require('butterfly.git_diff_fzf').pick { base = 'HEAD' }
end, { desc = 'Git Diff w/ context (vs HEAD)' })

return M
