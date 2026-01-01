local M = {}

local DEFAULT_SCOPE_NODE_TYPES = { 'function_declaration', 'function_definition', 'method_declaration' }

local scope_node_types_by_filetype = {
	lua = { 'function_declaration', 'function_definition', 'local_function' },
	go = { 'function_declaration', 'method_declaration', 'type_spec' },
	fish = { 'function_definition' },
	zig = { 'function_declaration' },
}

local ignored_context_node_types_by_filetype = {
	go = { 'import_declaration', 'import_spec', 'import_spec_list' },
}

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
---@return ScopeInfo?, boolean?
local function get_scope_at_line(filepath, line)
	local abs_path = vim.fn.fnamemodify(filepath, ':p')
	local bufnr = load_file_buffer(abs_path)

	if bufnr == -1 then
		return nil, false
	end

	if vim.bo[bufnr].filetype == '' then
		local detected = vim.filetype.match { filename = abs_path }
		if detected and detected ~= '' then
			vim.bo[bufnr].filetype = detected
		end
	end

	local ft = vim.bo[bufnr].filetype

	local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not ok or not parser then
		return nil, false
	end

	local tree = parser:parse()[1]
	if not tree then
		return nil, false
	end

	local row = math.max(0, line - 1)
	local root = tree:root()
	local node = root:named_descendant_for_range(row, 0, row, 0)

	local scope_node_types = scope_node_types_by_filetype[ft] or DEFAULT_SCOPE_NODE_TYPES

	local function is_go_build_tag_comment(n)
		if not n or ft ~= 'go' then
			return false
		end

		if n:type() ~= 'comment' then
			return false
		end

		local text = vim.treesitter.get_node_text(n, bufnr) or ''
		return text:match '^//%s*go:build%s+.+' ~= nil or text:match '^//%s*%+build%s+.+' ~= nil
	end

	local function is_go_build_tag_blank_line(row0)
		if ft ~= 'go' or row0 < 0 then
			return false
		end

		local cur = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ''
		if not cur:match '^%s*$' then
			return false
		end

		local max_lookback = 5
		for i = 1, max_lookback do
			local r = row0 - i
			if r < 0 then
				break
			end

			local prev = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ''
			if prev:match '^%s*$' then
				-- keep scanning upward
			elseif prev:match '^//%s*go:build%s+.+' or prev:match '^//%s*%+build%s+.+' then
				return true
			else
				return false
			end
		end

		return false
	end

	local function is_ignored_context_node(n)
		if not n then
			return false
		end

		local types = ignored_context_node_types_by_filetype[ft]
		if not types then
			return false
		end

		local t = n:type()
		for _, ignored_type in ipairs(types) do
			if t == ignored_type then
				return true
			end
		end

		return false
	end

	local ignored = false
	local check = node
	while check do
		if is_ignored_context_node(check) or is_go_build_tag_comment(check) then
			ignored = true
			break
		end
		check = check:parent()
	end

	if not ignored and is_go_build_tag_blank_line(row) then
		ignored = true
	end

	while node do
		local node_type = node:type()

		for _, scope_type in ipairs(scope_node_types) do
			if node_type == scope_type then
				local name = nil

				for child in node:iter_children() do
					local child_type = child:type()
					if child_type == 'name' or child_type == 'identifier' or child_type == 'field_identifier' or child_type == 'type_identifier' then
						name = vim.treesitter.get_node_text(child, bufnr)
						break
					end
				end

				if name then
					local signature = vim.treesitter.get_node_text(node, bufnr)
					if node_type == 'type_spec' then
						signature = 'type ' .. signature
					end

					return { name = name, signature = signature, kind = 'function' }, ignored
				end
			end
		end

		node = node:parent()
	end

	return nil, ignored
end

local tree_icons = { vertical = '│ ', middle = '├╴', last = '└╴' }

---@param filepath string
---@param line number
---@return string?
local function get_context_line(filepath, line)
	local abs_path = vim.fn.fnamemodify(filepath, ':p')
	local bufnr = load_file_buffer(abs_path)

	if bufnr == -1 then
		return nil
	end

	local total = vim.api.nvim_buf_line_count(bufnr)
	if total == 0 then
		return nil
	end

	local function find_non_empty(idx_start, num_lines, dir)
		-- Helper to get lines
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
			local trimmed = l:gsub('^%s+', '')
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

---@param item table
---@return snacks.picker.Highlight[]
local function format_item(item, _)
	local ret = {} ---@type snacks.picker.Highlight[]

	-- 1. Handle Header
	if item.is_header then
		local filename = vim.fn.fnamemodify(item.file, ':t')
		ret[#ret + 1] = { filename, 'GitDiffFzfFilename' }
		return ret
	end

	-- 2. Tree Structure Icons
	local icon = item.last and tree_icons.last or tree_icons.middle
	ret[#ret + 1] = { icon, 'SnacksPickerTree' }
	ret[#ret + 1] = { ' ' }

	-- 3. Resolve Buffer, Filetype, and Lang (MOVED UP)
	local lang = item.lang
	local ft = item.ft
	local abs_path = vim.fn.fnamemodify(item.file, ':p')
	local bufnr = load_file_buffer(abs_path)

	-- Ensure FT and Lang are resolved
	if (not ft or ft == '') and bufnr ~= -1 then
		ft = vim.bo[bufnr].filetype
		if ft == '' then
			local detected = vim.filetype.match { filename = abs_path, buf = bufnr }
			if detected then
				ft = detected
				-- Cache it on the buffer so we don't re-detect every frame
				vim.bo[bufnr].filetype = ft
			end
		end
	end

	if not lang or lang == '' then
		lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
	end

	-- 4. Render Scope (Function signature)
	if item.scope and item.scope.signature then
		-- Clean the signature to just the first line for the picker display
		local signature = item.scope.signature:match '^[^\n]*' or item.scope.signature

		-- Strip leading whitespace for cleaner display
		signature = signature:gsub('^%s+', '')

		Snacks.picker.highlight.format(item, signature, ret, { lang = lang, ft = ft })
		return ret
	end

	-- 5. Render Context Line (Fallback)
	if bufnr == -1 then
		ret[#ret + 1] = { '(file level)', 'Comment' }
		return ret
	end

	local line_content = item.context_line or get_context_line(item.file, item.line)

	-- If we can't find any non-empty context line nearby, hide it.
	if not line_content then
		return {}
	end

	Snacks.picker.highlight.format(item, line_content, ret, { lang = lang, ft = ft })
	return ret
end

---@param opts? { base?: string, file?: string }
function M.pick(opts)
	opts = opts or {}
	local base = opts.base or 'HEAD'

	vim.api.nvim_set_hl(0, 'GitDiffFzfFilename', { fg = '#AED28C' })

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

		local function resolve_ft_and_lang(fname)
			local abs = vim.fn.fnamemodify(fname, ':p')
			local ft = vim.filetype.match { filename = abs }
			if not ft or ft == '' then
				local ext = fname:match '%.([%w_]+)$'
				local map = { lua = 'lua', go = 'go', zig = 'zig', fish = 'fish' }
				ft = ext and map[ext] or nil
			end
			local lang = ft and (vim.treesitter.language.get_lang(ft) or ft) or nil
			return ft, lang
		end

		for _, file in ipairs(file_order) do
			local file_hunks = by_file[file]
			local ft, lang = resolve_ft_and_lang(file)

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
				local scope, ignored = get_scope_at_line(hunk.file, hunk.line)

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
							context_line = get_context_line(hunk.file, hunk.line)
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
					vim.api.nvim_win_set_cursor(0, { item.line, 0 })
				end
			end,
		}
	end)
end

vim.keymap.set('n', '<leader>gg',
	function()
		require('config.util_git').get_default_base_branch_async(
			function(branch)
				require('butterfly.git_diff_fzf').pick { base = branch }
			end
		)
	end,
	{ desc = 'Git Diff w/ context (vs default branch)' }
)

vim.keymap.set('n', '<leader>G',
	function()
		local file = vim.fn.expand '%'
		if not file or file == '' then
			vim.notify('No file in current buffer', vim.log.levels.WARN)
			return
		end

		require('config.util_git').get_default_base_branch_async(
			function(branch)
				require('butterfly.git_diff_fzf').pick { base = branch, file = file }
			end
		)
	end,
	{ desc = 'Git Diff current file (vs default branch)' }
)

vim.keymap.set('n', '<leader>gE',
	function()
		local file = vim.fn.expand '%'
		if not file or file == '' then
			vim.notify('No file in current buffer', vim.log.levels.WARN)
			return
		end

		require('butterfly.git_diff_fzf').pick { base = 'HEAD', file = file }
	end,
	{ desc = 'Git Diff current file (vs HEAD)' }
)

vim.keymap.set('n', '<leader>ge',
	function()
		require('butterfly.git_diff_fzf').pick { base = 'HEAD' }
	end,
	{ desc = 'Git Diff w/ context (vs HEAD)' }
)

return M
