-- === Jump List Float Display ===
local M = {}

local float_win = nil
local float_buf = nil
local current_entries = {}

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

	-- Get line (lnum is 1-indexed in jumplist, nvim_buf_get_lines is 0-indexed)
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

local function get_jumplist_entries()
	local jumplist, current_pos = unpack(vim.fn.getjumplist())

	if not jumplist or #jumplist == 0 then
		return { ' No jumps' }, {}
	end

	local current_buf = vim.api.nvim_get_current_buf()
	local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
	local cwd = vim.fn.getcwd() .. '/'

	local backward_jumps = {}
	for i = 1, current_pos do
		local jump = jumplist[i]
		local bufname = vim.api.nvim_buf_get_name(jump.bufnr)
		if bufname ~= '' and vim.startswith(bufname, cwd) then
			table.insert(backward_jumps, jump)
		end
	end

	-- Take last 4 (or fewer)
	local start_idx = math.max(1, #backward_jumps - 3)
	local entries = {}
	for i = start_idx, #backward_jumps do
		local jump = backward_jumps[i]
		table.insert(entries, {
			jump = jump,
			is_current = (jump.bufnr == current_buf and jump.lnum == cursor_lnum),
		})
	end

	if #entries == 0 then
		return { ' No jumps in cwd' }, {}
	end

	local lines = {}
	local highlights = {}
	local letters = { 'a', 'b', 'c', 'd' }

	-- Store entries globally for jump_to function
	current_entries = entries

	for i, entry in ipairs(entries) do
		local jump = entry.jump
		local line_content = get_line_content(jump.bufnr, jump.lnum)

		local display_text
		if line_content then
			display_text = truncate_left(line_content, config.truncate_len)
		else
			display_text = '<unavailable>'
		end

		local label = letters[i] .. '.'
		local line = string.format('%s %s', label, display_text)
		table.insert(lines, line)

		local line_idx = #lines - 1
		local label_len = #label

		table.insert(highlights, {
			line = line_idx,
			col_start = 0,
			col_end = label_len,
			hl = 'JumpIndex',
		})

		table.insert(highlights, {
			line = line_idx,
			col_start = label_len + 1,
			col_end = #line,
			hl = entry.is_current and 'JumpCurrent' or 'Comment',
		})
	end

	return lines, highlights
end

local function apply_highlights(highlights)
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
		return
	end

	local ns = vim.api.nvim_create_namespace('jumplist_float')
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
	vim.api.nvim_set_hl(0, 'JumpIndex', { fg = t.index, bg = t.bg, bold = true })
	vim.api.nvim_set_hl(0, 'JumpCurrent', { fg = t.current, bg = t.bg, bold = true })

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

	local lines, highlights = get_jumplist_entries()

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

-- Auto-refresh on jump-relevant events
local group = vim.api.nvim_create_augroup('JumplistFloat', { clear = true })

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

function M.jump_to(letter)
	local letter_to_idx = { a = 1, b = 2, c = 3, d = 4 }
	local idx = letter_to_idx[letter]
	if not idx or not current_entries[idx] then
		return
	end

	local jump = current_entries[idx].jump
	vim.cmd(string.format(
		'keepjumps buffer %d | keepjumps call cursor(%d, %d)',
		jump.bufnr, jump.lnum, jump.col + 1
	))
end

vim.keymap.set('n', '<leader>tj', M.toggle, { desc = '[T]oggle [J]umplist float display' })
vim.keymap.set('n', '<leader>ja', function() M.jump_to('a') end, { desc = '[J]ump to entry [a]' })
vim.keymap.set('n', '<leader>jb', function() M.jump_to('b') end, { desc = '[J]ump to entry [b]' })
vim.keymap.set('n', '<leader>jc', function() M.jump_to('c') end, { desc = '[J]ump to entry [c]' })
vim.keymap.set('n', '<leader>jd', function() M.jump_to('d') end, { desc = '[J]ump to entry [d]' })

return M
