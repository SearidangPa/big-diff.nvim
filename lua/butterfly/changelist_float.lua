-- === Change List Float Display ===
local M = {}

local float_win = nil
local float_buf = nil

local config = {
	width = 15,
	height = 4,
	max_width = 25,
	max_height = 8,
	border = 'none',
	winblend = 50,
	zindex = 1,
	truncate_len = 13,
}

-- Theme colors
local themes = {
	dark = {
		bg = '#242136',
		index = '#bb9af7',
		current = '#9ece6a',
	},
	light = {
		bg = '#FAF4ED',
		current = '#56949f',
		index = '#907aa9',
	},
}

local function get_line_content(bufnr, lnum)
	-- Check if buffer is valid and loaded
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	-- Load buffer if not loaded
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		vim.fn.bufload(bufnr)
	end

	-- Get line (lnum is 1-indexed, nvim_buf_get_lines is 0-indexed)
	local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
	if #lines == 0 then
		return nil
	end

	return lines[1]
end

local function truncate_left(str, max_len)
	-- Trim whitespace
	str = str:match('^%s*(.-)%s*$') or str

	if #str <= max_len then
		return str
	end

	return str:sub(1, max_len) .. '…'
end

local function get_changelist_entries()
	local current_buf = vim.api.nvim_get_current_buf()
	local changelist, current_pos = unpack(vim.fn.getchangelist(current_buf))

	if not changelist or #changelist == 0 then
		return { ' No changes' }, {}
	end

	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

	-- Get backward changes (entries before current position)
	local backward_changes = {}
	for i = 1, current_pos do
		local change = changelist[i]
		table.insert(backward_changes, change)
	end

	-- Take last 4 (or fewer)
	local start_idx = math.max(1, #backward_changes - 3)
	local entries = {}
	for i = start_idx, #backward_changes do
		local change = backward_changes[i]
		table.insert(entries, {
			change = change,
			is_current = (change.lnum == cursor_lnum),
		})
	end

	if #entries == 0 then
		return { ' No changes' }, {}
	end

	local lines = {}
	local highlights = {}
	local numbers = { '1', '2', '3', '4' }

	-- Store entries globally for jump_to function
	for i, entry in ipairs(entries) do
		local change = entry.change
		local line_content = get_line_content(current_buf, change.lnum)

		local display_text
		if line_content then
			display_text = truncate_left(line_content, config.truncate_len)
		else
			display_text = '<unavailable>'
		end

		local label = numbers[i] .. '.'
		local line = string.format('%s %s', label, display_text)
		table.insert(lines, line)

		local line_idx = #lines - 1
		local label_len = #label

		table.insert(highlights, {
			line = line_idx,
			col_start = 0,
			col_end = label_len,
			hl = 'ChangeIndex',
		})

		table.insert(highlights, {
			line = line_idx,
			col_start = label_len + 1,
			col_end = #line,
			hl = entry.is_current and 'ChangeCurrent' or 'Comment',
		})
	end

	return lines, highlights
end

local function apply_highlights(highlights)
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
		return
	end

	local ns = vim.api.nvim_create_namespace('changelist_float')
	vim.api.nvim_buf_clear_namespace(float_buf, ns, 0, -1)

	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(float_buf, ns, hl.line, hl.col_start, {
			end_col = hl.col_end,
			hl_group = hl.hl,
			priority = 100,
			strict = false,
		})
	end
end

local function create_float()
	local t = themes[vim.o.background] or themes.dark
	vim.api.nvim_set_hl(0, 'ChangeIndex', { fg = t.index, bg = t.bg, bold = true })
	vim.api.nvim_set_hl(0, 'ChangeCurrent', { fg = t.current, bg = t.bg, bold = true })

	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
		float_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[float_buf].buftype = 'nofile'
		vim.bo[float_buf].bufhidden = 'hide'
		vim.bo[float_buf].swapfile = false
		vim.bo[float_buf].modifiable = false
	end

	local win_opts = {
		relative = 'editor',
		width = config.width,
		height = config.height,
		row = 2 + 4 + 1, -- 2 for treesitter context, 4 for grapple float
		col = vim.o.columns - config.width,
		style = 'minimal',
		border = config.border,
		zindex = config.zindex,
		focusable = false,
	}

	if not float_win or not vim.api.nvim_win_is_valid(float_win) then
		float_win = vim.api.nvim_open_win(float_buf, false, win_opts)
		vim.wo[float_win].winblend = config.winblend
		vim.wo[float_win].cursorline = false
		vim.wo[float_win].number = false
		vim.wo[float_win].relativenumber = false
	else
		vim.api.nvim_win_set_config(float_win, win_opts)
	end
end

local function update_content()
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
		return
	end

	local lines, highlights = get_changelist_entries()

	-- Dynamic sizing with caps
	config.height = math.min(#lines, config.max_height)
	config.width = 4
	for _, line in ipairs(lines) do
		config.width = math.max(config.width, vim.fn.strdisplaywidth(line))
	end
	config.width = math.min(config.width, config.max_width)

	vim.bo[float_buf].modifiable = true
	vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
	vim.bo[float_buf].modifiable = false

	apply_highlights(highlights)
	create_float()
end

function M.toggle()
	if float_win and vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_win_close(float_win, true)
		float_win = nil
	else
		create_float()
		update_content()
	end
end

function M.show()
	create_float()
	update_content()
end

function M.refresh()
	if float_win and vim.api.nvim_win_is_valid(float_win) then
		update_content()
	end
end

-- Auto-refresh on change-relevant events
local group = vim.api.nvim_create_augroup('ChangelistFloat', { clear = true })

vim.api.nvim_create_autocmd({ 'CursorHold', 'BufEnter', 'WinEnter' }, {
	group = group,
	callback = function()
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.schedule(M.refresh)
		end
	end,
})

vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'ColorScheme' }, {
	group = group,
	callback = function()
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.schedule(M.refresh)
		end
	end,
})

vim.keymap.set('n', '<leader>tc', M.toggle, { desc = '[T]oggle [C]hangelist float display' })

return M
