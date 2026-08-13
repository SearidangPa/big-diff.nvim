local anchor = require('big-diff.nvim.review.anchor')
local composer = require('big-diff.nvim.review.composer')
local format = require('big-diff.nvim.review.format')
local handoff = require('big-diff.nvim.review.handoff')
local list_ui = require('big-diff.nvim.review.list')
local model = require('big-diff.nvim.review.model')
local persistence = require('big-diff.nvim.review.persistence')

local M = {}
local session
local namespace = vim.api.nvim_create_namespace('BigDiffReviewMarkers')
local commands_created = false
local configured = false

local defaults = {
  enabled = true,
  persist = true,
  require_saved = true,
  context_lines = 3,
  sign = 'R',
  mappings = { add = '<leader>ar', list = '<leader>aR', submit = '<leader>as' },
  open = nil,
  message_prefix = '',
  message_suffix = '',
}

local function notify(message, level) vim.notify('(big-diff review) ' .. message, level or vim.log.levels.INFO) end
local function emit(pattern) vim.api.nvim_exec_autocmds('User', { pattern = pattern, modeline = false }) end
local function active()
  if not session then notify('Review mode was not launched from Pi', vim.log.levels.WARN); return false end
  return true
end

local function review_by_id(id)
  if not session then return nil end
  for _, review in ipairs(session.state.reviews) do if review.id == id then return review end end
end

local function path_for_buf(buf_id)
  local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf_id))
  local prefix = session.repo_root .. '/'
  return name:sub(1, #prefix) == prefix and name:sub(#prefix + 1) or nil
end

local function buf_for_path(path)
  if not session then return nil end
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf_id) and path_for_buf(buf_id) == path then return buf_id end
  end
end

local function persistent_state()
  local state = {
    schema_version = 1,
    repo_root = session.repo_root,
    reviews = {},
    delivery_unknown = vim.deepcopy(session.state.delivery_unknown),
  }
  for _, review in ipairs(session.state.reviews) do
    local copy = vim.deepcopy(review)
    for key in pairs(copy) do if type(key) == 'string' and key:sub(1, 1) == '_' then copy[key] = nil end end
    state.reviews[#state.reviews + 1] = copy
  end
  return state
end

local function save()
  if not session or not session.config.persist then return true end
  return persistence.save(persistent_state(), session.state_path)
end

local function set_source_mappings(buf_id)
  if not vim.api.nvim_buf_is_valid(buf_id) or vim.bo[buf_id].buftype ~= '' then return end
  local mappings = session.config.mappings or {}
  if mappings.add and mappings.add ~= '' then
    vim.keymap.set('n', mappings.add, '<Cmd>BigDiffReviewAdd<CR>', { buffer = buf_id, desc = 'Add code review' })
    vim.keymap.set('x', mappings.add, function()
      local first, last = vim.fn.line('v'), vim.fn.line('.')
      if last < first then first, last = last, first end
      M.add({ buf_id = buf_id, line_start = first, line_end = last, visual = true })
    end, { buffer = buf_id, desc = 'Add code review' })
  end
  if mappings.list and mappings.list ~= '' then
    vim.keymap.set('n', mappings.list, M.list, { buffer = buf_id, desc = 'List code reviews' })
  end
  if mappings.submit and mappings.submit ~= '' then
    vim.keymap.set('n', mappings.submit, M.submit, { buffer = buf_id, desc = 'Submit code reviews' })
  end
end

local function sync_extmark(review, buf_id)
  local marks = review._extmarks or {}
  local mark = marks[buf_id]
  if mark then
    local position = vim.api.nvim_buf_get_extmark_by_id(buf_id, namespace, mark, {})
    if #position > 0 and review.side == 'new' then
      local span = math.max(0, (review.line_end or review.line_start) - review.line_start)
      review.line_start, review.line_end = position[1] + 1, position[1] + 1 + span
    end
  end
end

local function render_markers(buf_id)
  if not session or not vim.api.nvim_buf_is_valid(buf_id) then return end
  vim.api.nvim_buf_clear_namespace(buf_id, namespace, 0, -1)
  local path = path_for_buf(buf_id)
  if not path then return end
  local count = 0
  for _, review in ipairs(session.state.reviews) do
    if review.file_path == path then
      count = count + 1
      local row = math.max(0, (review.line_start or 1) - 1)
      row = math.min(row, math.max(0, vim.api.nvim_buf_line_count(buf_id) - 1))
      local id = vim.api.nvim_buf_set_extmark(buf_id, namespace, row, 0, {
        sign_text = session.config.sign,
        sign_hl_group = review.status == 'stale' and 'DiagnosticWarn' or 'DiagnosticInfo',
        virt_text = { { ' review ' .. count, review.status == 'stale' and 'DiagnosticWarn' or 'Comment' } },
        virt_text_pos = 'eol', priority = 210,
        end_row = math.min(review.line_end or review.line_start or 1, vim.api.nvim_buf_line_count(buf_id)),
        end_col = 0, right_gravity = false, end_right_gravity = true,
      })
      review._extmarks = review._extmarks or {}
      review._extmarks[buf_id] = id
    end
  end
  set_source_mappings(buf_id)
end

local function updated()
  save()
  if session then for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do render_markers(buf_id) end end
  emit('BigDiffReviewUpdated')
end

local function open_composer(review, is_new)
  composer.open(review, function(comment)
    if is_new then
      review.comment = comment
      session.state.reviews[#session.state.reviews + 1] = review
    else
      model.update_comment(review, comment)
    end
    updated()
  end)
end

local function capture_and_compose(buf_id, first, last, hunks)
  local fields, err = anchor.capture(session, buf_id, first, last, hunks)
  if not fields then notify(err, vim.log.levels.WARN); return end
  open_composer(model.new(fields), true)
end

M.add = function(opts)
  if not active() then return end
  opts = opts or {}
  local buf_id = opts.buf_id and (opts.buf_id == 0 and vim.api.nvim_get_current_buf() or opts.buf_id) or vim.api.nvim_get_current_buf()
  local data = _G.MiniDiff and _G.MiniDiff.get_buf_data(buf_id)
  if not data then notify('Current buffer is not enabled for diffing', vim.log.levels.WARN); return end
  local first = opts.line_start or vim.api.nvim_win_get_cursor(0)[1]
  local last = opts.line_end or first
  local hunks = anchor.hunks_in_range(data.hunks, first, last)
  if #hunks == 0 then notify('No changed hunk at the selected lines', vim.log.levels.WARN); return end
  if opts.visual or first ~= last then capture_and_compose(buf_id, first, last, hunks); return end
  if #hunks == 1 then
    local hunk = hunks[1]
    local h_first = hunk.buf_count > 0 and hunk.buf_start or math.max(hunk.buf_start, 1)
    local h_last = hunk.buf_count > 0 and hunk.buf_start + hunk.buf_count - 1 or h_first
    capture_and_compose(buf_id, h_first, h_last, { hunk })
    return
  end
  vim.ui.select(hunks, {
    prompt = 'Select changed hunk to review',
    format_item = function(hunk) return string.format('%s: new %d+%d, old %d+%d', hunk.type, hunk.buf_start, hunk.buf_count, hunk.ref_start, hunk.ref_count) end,
  }, function(hunk)
    if not hunk then return end
    local h_first = hunk.buf_count > 0 and hunk.buf_start or math.max(hunk.buf_start, 1)
    local h_last = hunk.buf_count > 0 and hunk.buf_start + hunk.buf_count - 1 or h_first
    capture_and_compose(buf_id, h_first, h_last, { hunk })
  end)
end

M.get_all = function() return session and vim.deepcopy(session.state.reviews) or {} end

M.revalidate = function()
  if not active() then return false end
  local valid = true
  for _, review in ipairs(session.state.reviews) do
    if review.status ~= 'submitted' then
      local buf_id = buf_for_path(review.file_path)
      local data
      if buf_id then
        sync_extmark(review, buf_id)
        data = _G.MiniDiff and _G.MiniDiff.get_buf_data(buf_id)
      elseif review.side == 'old' then
        local ref = review.source_target or session.target_ref
        local ref_text = vim.fn.system({ 'git', '-C', session.repo_root, 'show', ref .. ':' .. review.file_path })
        if vim.v.shell_error == 0 then data = { ref_text = ref_text } end
      end
      local ok, result = pcall(anchor.revalidate, review, buf_id, data)
      if not ok or not result then review.status = 'stale'; valid = false end
    end
  end
  updated()
  return valid
end

M.jump = function(id)
  if not active() then return end
  local review = review_by_id(id)
  if not review then return end
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(session.repo_root, review.file_path)))
  local row = review.line_start or 1
  vim.api.nvim_win_set_cursor(0, { math.min(row, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd('normal! zv')
  render_markers(vim.api.nvim_get_current_buf())
end

M.edit = function(id)
  if not active() then return end
  local review = review_by_id(id)
  if review then open_composer(review, false) end
end

M.delete = function(id)
  if not active() then return end
  for index, review in ipairs(session.state.reviews) do
    if review.id == id then table.remove(session.state.reviews, index); updated(); return end
  end
end

M.list = function()
  if not active() then return end
  list_ui.open(session.state.reviews, {
    jump = M.jump, edit = M.edit, delete = M.delete, submit = M.submit, revalidate = M.revalidate,
    reopen = function() vim.schedule(M.list) end,
  })
end

local function save_modified_buffers()
  local modified, non_file_modified = {}, {}
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf_id) and vim.bo[buf_id].modified then
      if vim.bo[buf_id].buftype == '' then modified[#modified + 1] = buf_id
      else non_file_modified[#non_file_modified + 1] = buf_id end
    end
  end
  if #non_file_modified > 0 then
    notify('Save or close modified review drafts before submission', vim.log.levels.ERROR)
    return false
  end
  if #modified == 0 then return true end
  if vim.fn.confirm(string.format('%d modified buffer(s) must be saved before submission.', #modified), '&Save all and submit\n&Cancel', 2) ~= 1 then return false end
  for _, buf_id in ipairs(modified) do
    local ok = pcall(vim.api.nvim_buf_call, buf_id, function() vim.cmd('update') end)
    if not ok or vim.bo[buf_id].modified then notify('Could not save ' .. vim.api.nvim_buf_get_name(buf_id), vim.log.levels.ERROR); return false end
  end
  return true
end

M.submit = function()
  if not active() then return end
  -- Submission exits Neovim, so modified buffers are handled even when
  -- require_saved is explicitly relaxed for anchor validation.
  if not save_modified_buffers() then return end
  if not M.revalidate() then notify('Stale reviews must be fixed or deleted before submission', vim.log.levels.ERROR); M.list(); return end
  local pending = {}
  for _, review in ipairs(session.state.reviews) do if review.status == 'pending' then pending[#pending + 1] = review end end
  if #pending == 0 then notify('There are no pending reviews to submit', vim.log.levels.WARN); return end
  if #pending > 500 then notify('A submission cannot contain more than 500 reviews', vim.log.levels.ERROR); return end
  local target = pending[1].source_target or 'index'
  local same_target = true
  for _, review in ipairs(pending) do if review.source_target ~= target then same_target = false; break end end
  session.target_description = same_target
      and (target == session.target_ref and session.request.targetDescription
        or (target == 'index' and 'working tree compared with Git index' or ('working tree compared with ' .. target)))
    or 'multiple configured diff targets'
  local markdown = session.config.message_prefix .. format.markdown(session, pending) .. session.config.message_suffix
  if #markdown > 900 * 1024 then notify('Review message is too large to submit', vim.log.levels.ERROR); return end
  if not save() then return end
  local references = {}
  for _, review in ipairs(pending) do references[#references + 1] = { id = review.id, revision = review.revision } end
  handoff.write_result(session.request, { reviewCount = #references, reviews = references, markdown = markdown })
  emit('BigDiffReviewSubmitted')
  vim.cmd('qall')
end

M.clear = function(opts)
  if not active() then return end
  opts = opts or {}
  local kept = {}
  for _, review in ipairs(session.state.reviews) do
    if opts.status and review.status ~= opts.status then kept[#kept + 1] = review end
  end
  session.state.reviews = kept
  updated()
end

M.cancel = function()
  if not active() then return end
  if vim.fn.confirm('Cancel this review and return to Pi?', '&Cancel review\n&Keep reviewing', 2) ~= 1 then return end
  save()
  emit('BigDiffReviewCancelled')
  vim.cmd('qall')
end

local function changed_files()
  local output = vim.fn.systemlist({
    'git', '-C', session.repo_root, 'diff', '--name-status', '--no-renames', session.target_ref, '--',
  })
  if vim.v.shell_error ~= 0 then return {} end
  local files = {}
  for _, line in ipairs(output) do
    local status, path = line:match('^(%S+)%s+(.+)$')
    if status and path then files[#files + 1] = { status = status, path = path } end
  end
  return files
end

local function dashboard()
  local files = changed_files()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'big-diff-review-dashboard'
  local lines, row_map = { 'Changed files (' .. session.target_description .. ')', '' }, {}
  if #files == 0 then lines[#lines + 1] = 'No changed files.' end
  for _, file in ipairs(files) do
    lines[#lines + 1] = string.format('[%s] %s', file.status, file.path)
    row_map[#lines] = file
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  vim.keymap.set('n', '<CR>', function()
    local file = row_map[vim.api.nvim_win_get_cursor(0)[1]]
    if not file then return end
    local full_path = vim.fs.joinpath(session.repo_root, file.path)
    if vim.fn.filereadable(full_path) ~= 1 then notify('Deleted files cannot be opened as working-tree buffers', vim.log.levels.WARN); return end
    vim.cmd.edit(vim.fn.fnameescape(full_path))
    vim.schedule(function() render_markers(vim.api.nvim_get_current_buf()) end)
  end, { buffer = buf, desc = 'Open changed file' })
  vim.keymap.set('n', 'q', M.cancel, { buffer = buf, desc = 'Cancel review' })
  vim.keymap.set('n', 's', M.submit, { buffer = buf, desc = 'Submit reviews' })
  vim.keymap.set('n', 'r', function() vim.api.nvim_buf_delete(buf, { force = true }); dashboard() end, { buffer = buf, desc = 'Refresh files' })
  vim.keymap.set('n', 'l', M.list, { buffer = buf, desc = 'List reviews' })
  if #files > 0 then vim.api.nvim_win_set_cursor(0, { 3, 0 }) end
end

local function create_commands()
  if commands_created then return end
  commands_created = true
  vim.api.nvim_create_user_command('BigDiffReviewAdd', function(command)
    M.add({ line_start = command.line1, line_end = command.line2, visual = command.range > 0 })
  end, { range = true, desc = 'Add a review for changed lines' })
  vim.api.nvim_create_user_command('BigDiffReviewList', M.list, { desc = 'List code reviews' })
  vim.api.nvim_create_user_command('BigDiffReviewSubmit', M.submit, { desc = 'Submit reviews to Pi' })
  vim.api.nvim_create_user_command('BigDiffReviewClear', function(command) M.clear({ status = command.args ~= '' and command.args or nil }) end,
    { nargs = '?', complete = function() return { 'pending', 'submitted', 'stale' } end, desc = 'Clear code reviews' })
  vim.api.nvim_create_user_command('BigDiffReviewCancel', M.cancel, { desc = 'Cancel review mode' })
end

M.setup = function(config)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), config or {})
  configured = true
  create_commands()
  return M
end

M.start = function(opts)
  opts = opts or {}
  if session then notify('Review mode is already active', vim.log.levels.WARN); return end
  if not configured then M.setup((_G.MiniDiff and _G.MiniDiff.config and _G.MiniDiff.config.review) or {}) end
  if M.config.enabled == false then notify('Review mode is disabled', vim.log.levels.ERROR); return end
  local request = handoff.read(opts.handoff_path or vim.env.BIG_DIFF_REVIEW_HANDOFF)
  local state, state_path = persistence.load(request.repoRoot, request.reviewStatePath)
  session = {
    request = request, repo_root = request.repoRoot, state = state, state_path = state_path, config = M.config,
    target_ref = request.targetRef, target_description = request.targetDescription,
  }
  -- A Pi-launched review intentionally overrides only the diff source target;
  -- the rest of the user's big-diff configuration remains in effect.
  _G.MiniDiff.config.source = { _G.MiniDiff.gen_source.git({ ref = session.target_ref }) }
  if state.delivery_unknown then
    notify('A previous review delivery is unknown. Inspect the Pi transcript before resubmitting.', vim.log.levels.ERROR)
    emit('BigDiffReviewDeliveryFailed')
  end

  local group = vim.api.nvim_create_augroup('BigDiffReview', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, { group = group, callback = function(event)
    if session then vim.schedule(function() render_markers(event.buf) end) end
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'MiniDiffUpdated', callback = function()
    local buf_id = vim.api.nvim_get_current_buf()
    if not session or not path_for_buf(buf_id) then return end
    vim.schedule(function()
      for _, review in ipairs(session.state.reviews) do
        if review.file_path == path_for_buf(buf_id) and review.status ~= 'submitted' then
          sync_extmark(review, buf_id)
          anchor.revalidate(review, buf_id, _G.MiniDiff.get_buf_data(buf_id))
        end
      end
      save(); render_markers(buf_id)
    end)
  end })
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do render_markers(buf_id) end
  if type(M.config.open) == 'function' then
    M.config.open({
      target_ref = session.target_ref,
      target_description = session.target_description,
      repo_root = session.repo_root,
    })
  else
    dashboard()
  end
end

create_commands()
return M
