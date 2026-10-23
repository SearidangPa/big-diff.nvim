---Previewer for picker items that carry a `diff` payload.
---
---Styles:
---  * `fancy`    - big-diff's own renderer (default)
---  * `syntax`   - plain diff text with `ft=diff`
---  * `terminal` - pipe the diff through an external pager such as `delta`
local M = {}

local config = require('big-diff.nvim.config')
local diff_render = require('big-diff.nvim.picker.render')

local namespace = vim.api.nvim_create_namespace('big-diff.nvim.picker.preview')

---@param ctx snacks.picker.preview.ctx
local function preview_syntax(ctx)
  ctx.preview:scratch()
  ctx.preview:set_lines(vim.split(ctx.item.diff, '\n', { plain = true }))
  ctx.preview:highlight({ ft = 'diff' })
end

---@param ctx snacks.picker.preview.ctx
local function preview_fancy(ctx)
  local options = config.get_picker_config().preview
  local buf = ctx.preview:scratch()
  diff_render.render(buf, namespace, ctx.item.diff, {
    block_header = false,
    max_hunk_lines = options.max_hunk_lines,
    hunk_header = options.hunk_header,
    annotations = ctx.item.annotations or ctx.picker.opts.annotations,
  })
  Snacks.util.wo(ctx.win, { wrap = false, number = false })
end

---@param ctx snacks.picker.preview.ctx
local function preview_terminal(ctx)
  local cmd = vim.deepcopy(config.get_picker_config().preview.cmd)
  if cmd[1] == 'delta' and not vim.tbl_contains(cmd, '--dark') and not vim.tbl_contains(cmd, '--light') then
    table.insert(cmd, 2, '--' .. vim.o.background)
  end
  Snacks.picker.preview.cmd(cmd, ctx, { input = ctx.item.diff })
end

---@param ctx snacks.picker.preview.ctx
function M.preview(ctx)
  local item = ctx.item
  if item then ctx.preview:set_title(item.rel_file or item.file or 'Diff') end

  if not item or not item.diff or item.diff == '' then
    if item and item.file and vim.fn.filereadable(item.file) == 1 then return Snacks.picker.preview.file(ctx) end
    return Snacks.picker.preview.none(ctx)
  end

  local style = config.get_picker_config().preview.style
  if style == 'terminal' and vim.fn.executable(config.get_picker_config().preview.cmd[1]) == 0 then style = 'fancy' end

  if style == 'syntax' then
    return preview_syntax(ctx)
  elseif style == 'terminal' then
    return preview_terminal(ctx)
  end

  local ok, err = pcall(preview_fancy, ctx)
  if not ok then
    vim.notify('big-diff: fancy diff preview failed: ' .. tostring(err), vim.log.levels.WARN)
    preview_syntax(ctx)
  end
end

return M
