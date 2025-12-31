local M = {}

local float_win = nil
local float_buf = nil
local diff_entries = {}
local save_order = {}
local save_counter = 0
local current_entry_idx = nil

local config = {
	width = 15,
	height = 4,
	max_width = 25,
	max_height = 9,
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


local function apply_highlights(highlights)
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then return end

	local ns = vim.api.nvim_create_namespace('butterfly_float')
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

local function get_diff_hunks(callback)
	vim.system(
		{ 'git', 'diff', 'HEAD', '--unified=0' },
		{ text = true },
		function(obj)
			local hunks = {}
			local output = obj.stdout or ''
			local current_file = nil
			for line in output:gmatch('[^\n]+') do
				local file = line:match('^%+%+%+ b/(.+)$')
				if file then
					current_file = file
				elseif current_file then
					local start_line = line:match('^@@ .* %+(%d+)')
					if start_line then
						table.insert(hunks, { file = current_file, line = tonumber(start_line) })
					end
				end
			end
			vim.schedule(function()
				callback(hunks)
			end)
		end
	)
end

local function_node_types = {
	lua = { 'function_declaration', 'function_definition', 'local_function' },
	go = { 'function_declaration', 'method_declaration' },
	fish = { 'function_definition' },
	zig = { 'function_declaration' },
}

---@param filepath string
---@param line number
---@return string?
local function get_function_at_line(filepath, line)
	local abs_path = vim.fn.fnamemodify(filepath, ':p')
	local bufnr = vim.fn.bufnr(abs_path)

	if bufnr == -1 then
		if not vim.loop.fs_stat(abs_path) then return nil end
		bufnr = vim.fn.bufadd(abs_path)
		vim.fn.bufload(bufnr)
	end

	local ft = vim.bo[bufnr].filetype
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not ok or not parser then return nil end

	local tree = parser:parse()[1]
	if not tree then return nil end

	local root = tree:root()
	local node_types = function_node_types[ft] or { 'function_declaration', 'function_definition', 'method_declaration' }
	local row = math.max(0, line - 1)

	local node = root:named_descendant_for_range(row, 0, row, 0)
	while node do
		local ntype = node:type()
		for _, ftype in ipairs(node_types) do
			if ntype == ftype then
				for child in node:iter_children() do
					if child:type() == 'name' or child:type() == 'identifier' or child:type() == 'field_identifier' then
						return vim.treesitter.get_node_text(child, bufnr)
					end
				end
			end
		end
		node = node:parent()
	end
	return nil
end

local function get_diff_function_names(callback)
	get_diff_hunks(function(hunks)
		table.sort(hunks, function(a, b)
			local abs_a = vim.fn.fnamemodify(a.file, ':p')
			local abs_b = vim.fn.fnamemodify(b.file, ':p')
			local name_a = get_function_at_line(a.file, a.line) or vim.fn.fnamemodify(a.file, ':t')
			local name_b = get_function_at_line(b.file, b.line) or vim.fn.fnamemodify(b.file, ':t')
			local order_a = save_order[abs_a .. ':' .. name_a] or 0
			local order_b = save_order[abs_b .. ':' .. name_b] or 0
			return order_a > order_b
		end)

		local seen = {}
		local lines = {}
		local highlights = {}
		diff_entries = {}

		for _, hunk in ipairs(hunks) do
			local name = get_function_at_line(hunk.file, hunk.line)
			if not name then
				name = vim.fn.fnamemodify(hunk.file, ':t')
			end

			if not seen[name] then
				seen[name] = true
				local idx = #lines + 1
				local line = string.format('%d %s', idx, truncate_middle(name))
				table.insert(lines, line)
				table.insert(diff_entries, { file = hunk.file, line = hunk.line })
				table.insert(highlights, {
					line = idx - 1,
					col_start = 0,
					col_end = #tostring(idx),
					hl = 'ButterflyIndex',
				})

				if idx == current_entry_idx then
					table.insert(highlights, {
						line = idx - 1,
						col_start = 0,
						col_end = #line,
						hl = 'ButterflyCurrent',
					})
				else -- highlight comment
					table.insert(highlights, {
						line = idx - 1,
						col_start = 1,
						col_end = #line,
						hl = 'Comment',
					})
				end
			end
		end

		callback(lines, highlights)
	end)
end

local function create_float(num_lines)
	local t = themes[vim.o.background] or themes.dark
	vim.api.nvim_set_hl(0, 'ButterflyIndex', { fg = t.index, bg = t.bg, bold = true })
	vim.api.nvim_set_hl(0, 'ButterflyCurrent', { fg = t.current, bg = t.bg, bold = true })

	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
		float_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[float_buf].buftype = 'nofile'
		vim.bo[float_buf].bufhidden = 'hide'
		vim.bo[float_buf].swapfile = false
		vim.bo[float_buf].modifiable = false
	end

	local height = num_lines or 1
	if height < 1 then
		height = 1
	end
	local win_opts = {
		relative = 'editor',
		width = config.width,
		height = height,
		row = (vim.o.lines - height) - 1,
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

local function update_display()
	if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then return end

	get_diff_function_names(function(lines, highlights)
		if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then return end

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
		create_float(#lines)
	end)
end

function M.toggle()
	if float_win and vim.api.nvim_win_is_valid(float_win) then
		vim.api.nvim_win_close(float_win, true)
		float_win = nil
	else
		create_float()
		update_display()
	end
end

function M.show()
	create_float()
	update_display()
end

function M.refresh()
	if float_win and vim.api.nvim_win_is_valid(float_win) then
		update_display()
	end
end

function M.goto_entry(n)
	local entry = diff_entries[n]
	if not entry then return end
	current_entry_idx = n
	vim.cmd('edit ' .. vim.fn.fnameescape(entry.file))
	vim.api.nvim_win_set_cursor(0, { entry.line, 0 })
	M.refresh()
end

function M.pick()
	get_diff_function_names(function(lines, _)
		local items = {}
		for i, line in ipairs(lines) do
			table.insert(items, { text = line, idx = i })
		end

		Snacks.picker({
			title = "Butterfly",
			items = items,
			format = function(item)
				return { { item.text, "SnacksPickerLabel" } }
			end,
			layout = {
				layout = {
					box = "horizontal",
					width = 0.8,
					min_width = 120,
					height = 0.6,
					{
						box = "vertical",
						border = "rounded",
						title = "{title} {live} {flags}",
						{ win = "input", height = 1,     border = "bottom" },
						{ win = "list",  border = "none" },
					},
				},
			},
			confirm = function(picker, item)
				picker:close()
				if item then
					M.goto_entry(item.idx)
				end
			end,
		})
	end)
end

local group = vim.api.nvim_create_augroup('ButterflyFloat', { clear = true })

vim.api.nvim_create_autocmd({ 'BufEnter', 'WinResized', 'VimResized', 'ColorScheme' }, {
	group = group,
	callback = function()
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.schedule(M.refresh)
		end
	end,
})

vim.api.nvim_create_autocmd('BufWritePost', {
	group = group,
	callback = function(ev)
		local filepath = vim.api.nvim_buf_get_name(ev.buf)
		local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
		local func_name = get_function_at_line(filepath, cursor_line)
		local key = filepath .. ':' .. (func_name or vim.fn.fnamemodify(filepath, ':t'))

		save_counter = save_counter + 1
		save_order[key] = save_counter
		if float_win and vim.api.nvim_win_is_valid(float_win) then
			vim.schedule(M.refresh)
		end
	end,
})

vim.api.nvim_create_user_command('ButterflyToggle', M.toggle, { desc = 'Butterfly Toggle' })
vim.api.nvim_create_user_command('ButterflyRefresh', M.refresh, { desc = 'Butterfly Refresh ' })

for i = 1, 9 do
	vim.keymap.set('n', '<leader>b' .. i, function() M.goto_entry(i) end, { desc = '[B]utterfly go to ' .. i })
end

vim.keymap.set('n', '<leader>bb', M.pick, { desc = '[B]utterfly pick' })

M.setup = function()
	local original_handler = vim.lsp.handlers['workspace/applyEdit']
	if original_handler then
		vim.lsp.handlers['workspace/applyEdit'] = function(err, result, ctx)
			local response = original_handler(err, result, ctx)
			if float_win and vim.api.nvim_win_is_valid(float_win) then
				vim.schedule(M.refresh)
			end
			return response
		end
	end

	vim.schedule(M.show)
end

return M
