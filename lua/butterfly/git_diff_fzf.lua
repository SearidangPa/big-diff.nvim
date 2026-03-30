local M = {}

local ctx = require("butterfly.utils_picker_context")
local util_git = require("butterfly.util_git")
local util_picker = require("butterfly.util_picker")
local uv = vim.uv or vim.loop

local jump_label_attached = setmetatable({}, { __mode = "k" })

local JUMP_LABELS = "abcdefghijklmnopqrstuvwxyz"

local function build_label_actions()
	local actions = {}
	local keys = {}

	for i = 1, #JUMP_LABELS do
		local label = JUMP_LABELS:sub(i, i)
		local action_name = "jump_label_" .. label
		actions[action_name] = function(picker)
			local target_idx = nil
			for item, idx in picker:iter() do
				if item and item.jump_label == label then
					target_idx = idx
					break
				end
			end

			if not target_idx then
				return
			end

			picker.list:view(target_idx)
			picker:action("confirm")
		end
		keys["<M-" .. label .. ">"] = { action_name, mode = { "i", "n" } }
	end

	return actions, keys
end

local function assign_jump_labels(picker)
	if not picker or picker.closed then
		return
	end

	local label_idx = 0
	for item in picker:iter() do
		if item.is_header then
			item.jump_label = nil
		else
			label_idx = label_idx + 1
			if label_idx <= #JUMP_LABELS then
				item.jump_label = JUMP_LABELS:sub(label_idx, label_idx)
			else
				item.jump_label = nil
			end
		end
	end

	picker.list:update({ force = true })
end

local function is_test_path(file_path)
	return file_path:match("^integration_tests[/\\]")
		 or file_path:match("[^%w]integration_tests[/\\]")
		 or file_path:match("[/\\]integration_tests[/\\]")
		 or file_path:match("_test%.[^/\\]+$")
		 or file_path:match("_spec%.lua$")
end

local function format_item(item, opts)
	opts = opts or {}
	local ret = ctx.format_item(item, {
		header_hl_group = "ButterflyFileName",
		show_filename = opts.show_filename,
		show_tree = opts.show_filename,
	})

	if item.jump_label then
		ret[#ret + 1] = {
			col = 0,
			virt_text = {
				{ item.jump_label, "SnacksPickerLabel" },
			},
			virt_text_pos = "right_align",
			hl_mode = "combine",
		}
	end

	return ret
end

---@param git_root string
---@param file string
---@return string
local function to_absolute_path(git_root, file)
	return vim.fs.normalize(git_root .. "/" .. file)
end

---Process hunks and display picker (core logic extracted for reuse)
---@param opts {
---  exclude_tests?: boolean,
---  only_tests?: boolean,
---  file?: string,
---  exclude_file?: string,
---  git_root?: string
---}
---@param base string
---@param hunks table[]
local function process_hunks_and_show_picker(opts, base, hunks)
	local by_file = {}
	local file_order = {}
	local git_root = opts.git_root

	if not git_root or git_root == "" then
		vim.notify("Could not determine git root for diff", vim.log.levels.WARN)
		return
	end

	for _, hunk in ipairs(hunks) do
		local is_test = is_test_path(hunk.file)

		if opts.only_tests and not is_test then
			goto continue
		end

		if opts.exclude_tests and is_test then
			goto continue
		end

		if opts.exclude_file and hunk.file == opts.exclude_file then
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
	local label_actions, label_keys = build_label_actions()

	for _, file in ipairs(file_order) do
		local file_hunks = by_file[file]
		local abs_file = to_absolute_path(git_root, file)

		-- Batch: collect all line numbers for this file
		local lines = {}
		for _, hunk in ipairs(file_hunks) do
			lines[#lines + 1] = hunk.line
		end

		-- Single batch call: get all scopes + file cache (parses treesitter once)
		local scope_results, file_cache =
			 ctx.batch_get_scopes(abs_file, lines, { check_ignored = true })

		-- Get ft/lang from cache (already computed during batch_get_scopes)
		local ft = file_cache and file_cache.ft or nil
		local lang = file_cache and file_cache.lang or nil
		if not ft then
			ft, lang = ctx.resolve_ft_and_lang(abs_file)
		end

		local file_item = {
			file = abs_file,
			rel_file = file,
			line = file_hunks[1].line,
			pos = { file_hunks[1].line, 0 },
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
				local key = scope and scope.name
					 or ("line:" .. tostring(hunk.line))

				if not seen[key] then
					seen[key] = true
					non_import_children = non_import_children + 1

					local context_line = nil
					if not scope then
						context_line = ctx.get_context_line(abs_file, hunk.line)
					end

					local search_text = scope and scope.name
						 or context_line
						 or key

					table.insert(children, {
						file = abs_file,
						rel_file = hunk.file,
						line = hunk.line,
						pos = { hunk.line, 0 },
						count = hunk.count,
						scope = scope,
						context_line = context_line,
						ft = ft,
						lang = lang,
						text = file .. " " .. search_text,
						parent = file_item,
					})
				end
			end
		end

		if non_import_children > 0 then
			if not opts.file then
				table.insert(items, file_item)
			end

			if #children > 0 then
				children[#children].last = true
			end

			for _, child in ipairs(children) do
				table.insert(items, child)
			end
		end
	end

	Snacks.picker({
		title = "Git Diff: " .. base,
		items = items,
		format = function(item)
			return format_item(item, { show_filename = not opts.file })
		end,
		matcher = {
			keep_parents = true,
			sort = false,
		},
		actions = label_actions,
		win = {
			input = {
				keys = label_keys,
			},
		},
		on_show = function(picker)
			if jump_label_attached[picker] then
				return
			end
			jump_label_attached[picker] = true

			local prev_on_done = picker.matcher.opts.on_done
			picker.matcher.opts.on_done = function(matcher)
				if prev_on_done then
					prev_on_done(matcher)
				end
				util_picker.regroup_by_parent(picker, matcher, not opts.file)
				assign_jump_labels(picker)
			end

			assign_jump_labels(picker)
		end,

		layout = {
			fullscreen = true,
			layout = {
				config = function(layout)
					local root = layout.layout
					if not root or root.box ~= "vertical" then
						return
					end

					if root.min_height ~= 30 then
						return
					end

					local list = root[2]
					local preview = root[3]
					if not list or list.win ~= "list" then
						return
					end

					if not preview or preview.win ~= "preview" then
						return
					end

					list.height = 0.4
					preview.height = nil
				end,
			},
		},
		confirm = function(picker, item)
			picker:close()
			if item then
				vim.cmd("edit " .. vim.fn.fnameescape(item.file))
				local line_count = vim.api.nvim_buf_line_count(0)
				local target_line = math.max(1, math.min(item.line, line_count))
				vim.api.nvim_win_set_cursor(0, { target_line, 0 })
			end
		end,
	})
end

---@param path string
---@return boolean
local function path_exists(path)
	if not path or path == "" or not uv then
		return false
	end

	if uv.fs_stat(path) then
		return true
	end

	local abs = vim.fn.fnamemodify(path, ":p")
	return uv.fs_stat(abs) ~= nil
end

---@param path string
---@return string
local function strip_position_suffix(path)
	local stripped = path:match("^(.+):%d+:%d+$")
	if stripped then
		if path_exists(stripped) or not path_exists(path) then
			return stripped
		end
	end

	stripped = path:match("^(.+):%d+$")
	if stripped then
		if path_exists(stripped) or not path_exists(path) then
			return stripped
		end
	end

	return path
end

---@param opts? {
---  base?: string,
---  file?: string,
---  exclude_tests?: boolean,
---  only_tests?: boolean,
---  exclude_file?: string,
---  git_root?: string
---}
function M.pick(opts)
	opts = opts or {}
	local base = opts.base or "HEAD"

	if opts.file and opts.file ~= "" then
		opts.file = strip_position_suffix(opts.file)
	end

	local git_root = opts.git_root

	if not git_root and opts.file and opts.file ~= "" then
		git_root = util_git.find_git_root_for_path(opts.file)
	end
	if not git_root then
		git_root = util_git.find_git_root()
	end

	if not git_root then
		vim.notify(
			"Current buffer is not in a git repository",
			vim.log.levels.WARN
		)
		return
	end

	opts.git_root = git_root

	util_git.get_diff_hunks(base, opts.file, function(hunks)
		process_hunks_and_show_picker(opts, base, hunks)
	end, { git_root = git_root })
end

---@param file? string
---@return string?, string?
local function resolve_current_file(file)
	file = file or vim.api.nvim_buf_get_name(0)
	if not file or file == "" then
		return nil, nil
	end

	file = strip_position_suffix(file)

	local git_root = util_git.find_git_root_for_path(file)
		 or util_git.find_git_root()
	if not git_root then
		return nil, nil
	end

	return util_git.to_repo_relative_path(file, git_root), git_root
end

---@param opts? {
---  file?: string,
---  exclude_tests?: boolean,
---  only_tests?: boolean,
---  fallback?: string,
---  exclude_file?: string,
---  git_root?: string
---}
function M.pick_vs_default_branch(opts)
	opts = opts or {}

	if opts.file and opts.file ~= "" then
		opts.file = strip_position_suffix(opts.file)
	end

	local git_root = opts.git_root
	if not git_root and opts.file and opts.file ~= "" then
		git_root = util_git.find_git_root_for_path(opts.file)
	end
	if not git_root then
		git_root = util_git.find_git_root()
	end

	util_git.get_default_base_branch_async(function(branch)
		M.pick({
			base = branch,
			file = opts.file,
			exclude_tests = opts.exclude_tests,
			only_tests = opts.only_tests,
			exclude_file = opts.exclude_file,
			git_root = git_root,
		})
	end, { fallback = opts.fallback, git_root = git_root })
end

function M.pick_tests_vs_default_branch()
	local resolved, git_root = resolve_current_file()
	M.pick_vs_default_branch({
		only_tests = true,
		exclude_file = resolved,
		git_root = git_root,
	})
end

function M.pick_context_vs_default_branch()
	local resolved, git_root = resolve_current_file()
	M.pick_vs_default_branch({
		exclude_tests = true,
		exclude_file = resolved,
		git_root = git_root,
	})
end

---@param file? string
function M.pick_file_vs_default_branch(file)
	local resolved, git_root = resolve_current_file(file)
	if not resolved then
		vim.notify("No file in current buffer", vim.log.levels.WARN)
		return
	end

	M.pick_vs_default_branch({ file = resolved, git_root = git_root })
end

---@param opts? {
---  file?: string,
---  exclude_tests?: boolean,
---  only_tests?: boolean,
---  exclude_file?: string,
---  git_root?: string
---}
function M.pick_vs_head(opts)
	opts = opts or {}
	local resolved, git_root = resolve_current_file()
	M.pick({
		base = "HEAD",
		file = opts.file,
		exclude_tests = opts.exclude_tests,
		only_tests = opts.only_tests,
		exclude_file = resolved,
		git_root = opts.git_root or git_root,
	})
end

---@param file? string
function M.pick_file_vs_head(file)
	local resolved, git_root = resolve_current_file(file)
	if not resolved then
		vim.notify("No file in current buffer", vim.log.levels.WARN)
		return
	end

	M.pick({
		base = "HEAD",
		file = resolved,
		git_root = git_root,
	})
end

return M
