-- === Grapple Float Display ===
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
	no_truncate_max = 14
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



local function truncate_middle(str)
	if #str <= config.no_truncate_max then
		return str
	end
	-- split on: space, underscore, hyphen (and collapse repeats)
	local parts = {}
	for p in str:gmatch("[^%s_%-%+]+") do
		parts[#parts + 1] = p
	end

	if #parts == 0 then
		return str:sub(1, 8)
	end

	if #parts <= 3 then
		for i, p in ipairs(parts) do
			parts[i] = p:sub(1, 4)
		end
		return table.concat(parts, "_")
	end

	-- For long names: first + second_last + last (4 chars each)
	local first = parts[1]:sub(1, 4)
	local second_last = parts[#parts - 1]:sub(1, 4)
	local last = parts[#parts]:sub(1, 4)
	return table.concat({ first, second_last, last }, "_")
end

local function get_grapple_tags()
	local ok, grapple = pcall(require, 'grapple')
	if not ok then return {}, {} end

	local tags = grapple.tags()
	if not tags or #tags == 0 then
		return { ' No tags' }, {}
	end

	local current_file = vim.fn.expand('%:p')
	local lines = {}
	local highlights = {}

	for i, tag in ipairs(tags) do
		if i > 4 then break end

		local name = vim.fn.fnamemodify(tag.path, ':t:r')
		name = truncate_middle(name)
		local is_current = tag.path == current_file
		local icon = is_current and '●' or '○'

		local line = string.format('%s %s', icon, name)
		table.insert(lines, line)

		local line_idx = #lines - 1
		local icon_byte_len = #icon

		table.insert(highlights, {
			line = line_idx,
			col_start = 0,
			col_end = icon_byte_len,
			hl = 'GrappleIndex'
		})

		table.insert(highlights, {
			line = line_idx,
			col_start = icon_byte_len + 1,
			col_end = #line,
			hl = is_current and 'GrappleCurrent' or 'Comment'
		})
	end

	return lines, highlights
end

local function apply_highlights(highlights)
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then return end

	local ns = vim.api.nvim_create_namespace('grapple_float')
	vim.api.nvim_buf_clear_namespace(float_buf, ns, 0, -1)

	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_set_extmark(
			float_buf,
			ns,
			hl.line,
			hl.col_start,
			{
				end_col = hl.col_end,
				hl_group = hl.hl,
				priority = 100,
				strict = false,
			}
		)
	end
end

local function create_float()
	local t = themes[vim.o.background] or themes.dark
	vim.api.nvim_set_hl(0, 'GrappleIndex', { fg = t.index, bg = t.bg, bold = true })
	vim.api.nvim_set_hl(0, 'GrappleCurrent', { fg = t.current, bg = t.bg, bold = true })

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
		row = 2, -- 2 for treesitter context
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
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then return end

	local lines, highlights = get_grapple_tags()

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

-- Auto-refresh and reposition
local group = vim.api.nvim_create_augroup('GrappleFloat', { clear = true })

vim.api.nvim_create_autocmd('User', {
	group = group,
	pattern = { 'GrappleTag', 'GrappleUntag', 'GrappleReset', 'GrappleTagChanged' },
	callback = function()
		vim.schedule(M.refresh)
	end,
})

vim.api.nvim_create_autocmd({ 'BufEnter', 'WinResized', 'VimResized', 'ColorScheme' }, {
	group = group,
	callback = function()
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.schedule(M.refresh)
		end
	end,
})

vim.keymap.set('n', '<leader>tg', M.toggle, { desc = '[T]oggle [G]rapple float display' })

-- toggle automatically on startup
M.setup = function()
	vim.schedule(M.show)
end

return M
