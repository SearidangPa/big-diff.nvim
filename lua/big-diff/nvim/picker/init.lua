local M = {}

local config = require("big-diff.nvim.config")
local diff_parse = require("big-diff.nvim.patch")
local diff_preview = require("big-diff.nvim.picker.preview")
local diff_render = require("big-diff.nvim.picker.render")
local picker_context = require("big-diff.nvim.utils_picker_context")
local git_util = require("big-diff.nvim.utils_git")
local picker_util = require("big-diff.nvim.utils_picker")
local filesystem = vim.uv or vim.loop

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
            for item, item_index in picker:iter() do
                if item and item.jump_label == label then
                    target_idx = item_index
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
        if item.is_header and not item.standalone then
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

local function format_item(item, options)
    options = options or {}
    -- A standalone row is the only row for its file, so it always needs the
    -- name even when the picker is scoped to a single file.
    local show_filename = options.show_filename or item.standalone or false
    local formatted_item = picker_context.format_item(item, {
        header_hl_group = "BigDiffFileName",
        show_filename = show_filename,
        show_tree = show_filename and not item.standalone,
    })

    for _, badge in ipairs(item.badges or {}) do
        formatted_item[#formatted_item + 1] = { " " }
        formatted_item[#formatted_item + 1] = { badge[1], badge[2] }
    end

    if item.jump_label then
        formatted_item[#formatted_item + 1] = {
            col = 0,
            virt_text = {
                { item.jump_label, "SnacksPickerLabel" },
            },
            virt_text_pos = "right_align",
            hl_mode = "combine",
        }
    end

    return formatted_item
end

---@param git_root string
---@param file string
---@return string
local function to_absolute_path(git_root, file)
    return vim.fs.normalize(git_root .. "/" .. file)
end

---Filters every git diff picker accepts.
---@class GitDiffFilterOpts
---@field exclude_tests? boolean
---@field only_tests? boolean
---@field file? string
---@field exclude_file? string
---@field git_root? string
---@field staged? boolean true: index only, false: worktree only, nil: both
---@field group? boolean one item per file instead of one per hunk
---@field ignore_whitespace? boolean
---@field annotations? BigDiffAnnotation[]
---@field pattern? string initial picker input

---@param options GitDiffFilterOpts
---@param block BigDiffBlock
---@return boolean
local function is_filtered_out(options, block)
    local is_test = is_test_path(block.file)

    if options.only_tests and not is_test then
        return true
    end

    if options.exclude_tests and is_test then
        return true
    end

    if options.exclude_file and block.file == options.exclude_file then
        return true
    end

    return false
end

---@param options GitDiffFilterOpts
---@param base string
---@return string
local function picker_title(options, base)
    local title = "Git Diff: "
    if options.staged == true then
        title = title .. "staged vs " .. base
    elseif options.staged == false then
        title = title .. "unstaged"
    else
        title = title .. base
    end

    local flags = {}
    if options.ignore_whitespace then
        flags[#flags + 1] = "-w"
    end
    if options.group then
        flags[#flags + 1] = "grouped"
    end
    if #flags > 0 then
        title = title .. " (" .. table.concat(flags, ", ") .. ")"
    end

    return title
end

---Builds picker items for one block: a file header plus one item per hunk,
---or a single item when the block carries no hunks (binary, mode-only,
---deleted) or when grouping is on.
---@param options GitDiffFilterOpts
---@param block BigDiffBlock
---@param git_root string
---@return table[]
local function block_items(options, block, git_root)
    local absolute_file = to_absolute_path(git_root, block.file)
    local badges = diff_render.badges(block)

    -- One entry per contiguous changed range, so a single -U3 hunk that
    -- touches two functions still yields two rows.
    ---@type { hunk: BigDiffHunk, line: number, count: number }[]
    local changes = {}
    for _, hunk in ipairs(block.hunks) do
        for _, change in ipairs(hunk.changes or {}) do
            changes[#changes + 1] = {
                hunk = hunk,
                line = math.max(1, change.line),
                count = math.max(1, change.count),
            }
        end
    end

    local scope_results, file_cache, filetype, treesitter_language
    do
        local lines = {}
        for _, change in ipairs(changes) do
            lines[#lines + 1] = change.line
        end

        -- Single batch call: parses treesitter once for the whole file.
        scope_results, file_cache = picker_context.batch_get_scopes(
            absolute_file,
            lines,
            { check_ignored = true }
        )

        filetype = file_cache and file_cache.filetype or nil
        treesitter_language = file_cache and file_cache.treesitter_language
            or nil
        if not filetype then
            filetype, treesitter_language =
                picker_context.resolve_ft_and_lang(absolute_file)
        end
    end

    local first_line = changes[1] and changes[1].line or 1

    local file_item = {
        file = absolute_file,
        rel_file = block.file,
        line = first_line,
        pos = { first_line, 0 },
        is_header = true,
        text = block.file,
        filetype = filetype,
        treesitter_language = treesitter_language,
        block = block,
        staged = block.staged,
        badges = badges,
        annotations = options.annotations,
        diff = diff_parse.to_text(block),
        deleted = block.delete ~= nil,
    }

    -- Nothing to hop to inside the working tree: show the file as one row.
    if #changes == 0 or options.group or block.delete then
        file_item.standalone = true
        return { file_item }
    end

    local seen = {}
    local children = {}

    for _, change in ipairs(changes) do
        local hunk = change.hunk
        local line, count = change.line, change.count
        local is_new_file_hunk = block.new ~= nil or (line == 1 and count > 10)
        local result = scope_results[line]
        local scope = result and result.scope or nil
        local ignored = result and result.ignored or false

        -- A change that starts in the import block but spills into real code
        -- still matters, so require the whole range to be ignorable.
        if ignored and count > 1 then
            ignored = picker_context.is_ignored_range(file_cache, line, count)
        end

        if is_new_file_hunk or not ignored then
            local key = scope and scope.name or ("line:" .. tostring(line))

            if not seen[key] then
                seen[key] = true

                local context_line = nil
                if not scope then
                    context_line = picker_context.get_context_line(
                        absolute_file,
                        line
                    )
                        -- git's own `@@ ... @@ func()` trailer is a free
                        -- fallback when treesitter has no parser.
                        or hunk.context
                end

                local search_text = scope and scope.name or context_line or key

                table.insert(children, {
                    file = absolute_file,
                    rel_file = block.file,
                    line = line,
                    pos = { line, 0 },
                    count = count,
                    scope = scope,
                    context_line = context_line,
                    filetype = filetype,
                    treesitter_language = treesitter_language,
                    text = block.file .. " " .. search_text,
                    parent = file_item,
                    block = block,
                    staged = block.staged,
                    annotations = options.annotations,
                    diff = diff_parse.to_text(block, { hunk }),
                })
            end
        end
    end

    if #children == 0 then
        return {}
    end

    children[#children].last = true

    -- Point the header at the first change that survived filtering.
    file_item.line = children[1].line
    file_item.pos = { children[1].line, 0 }

    local items = {}
    if not options.file then
        items[#items + 1] = file_item
    end
    for _, child in ipairs(children) do
        items[#items + 1] = child
    end

    return items
end

---@param picker table
---@param options GitDiffFilterOpts
---@param base string
---@param overrides table
local function reopen(picker, options, base, overrides)
    local pattern = picker.input
        and picker.input.filter
        and picker.input.filter.pattern
    picker:close()

    local next_options = vim.tbl_extend("force", options, overrides)
    next_options.base = base
    next_options.pattern = pattern ~= "" and pattern or nil
    M.pick(next_options)
end

---@param options GitDiffFilterOpts
---@param base string
local function build_toggle_actions(options, base)
    local actions = {
        big_diff_toggle_whitespace = function(picker)
            reopen(picker, options, base, {
                ignore_whitespace = not options.ignore_whitespace,
            })
        end,
        big_diff_toggle_staged = function(picker)
            local next_staged = nil
            if options.staged == nil then
                next_staged = true
            elseif options.staged == true then
                next_staged = false
            end
            reopen(picker, options, base, { staged = next_staged })
        end,
        big_diff_toggle_group = function(picker)
            reopen(picker, options, base, { group = not options.group })
        end,
    }

    local keys = {
        ["<M-W>"] = { "big_diff_toggle_whitespace", mode = { "i", "n" } },
        ["<M-S>"] = { "big_diff_toggle_staged", mode = { "i", "n" } },
        ["<M-G>"] = { "big_diff_toggle_group", mode = { "i", "n" } },
    }

    return actions, keys
end

---Process blocks and display picker (core logic extracted for reuse)
---@param options GitDiffFilterOpts
---@param base string
---@param blocks BigDiffBlock[]
local function process_blocks_and_show_picker(options, base, blocks)
    local git_root = options.git_root

    if not git_root or git_root == "" then
        vim.notify("Could not determine git root for diff", vim.log.levels.WARN)
        return
    end

    local items = {}
    for _, block in ipairs(blocks) do
        if not is_filtered_out(options, block) then
            vim.list_extend(items, block_items(options, block, git_root))
        end
    end

    local label_actions, label_keys = {}, {}
    if config.get_picker_config().jump_labels then
        label_actions, label_keys = build_label_actions()
    end
    local toggle_actions, toggle_keys = build_toggle_actions(options, base)
    local navigation_actions, navigation_keys = picker_util.header_navigation()
    local actions = vim.tbl_extend(
        "error",
        label_actions,
        toggle_actions,
        navigation_actions
    )
    local keys =
        vim.tbl_extend("error", label_keys, toggle_keys, navigation_keys)

    Snacks.picker({
        title = picker_title(options, base),
        items = items,
        pattern = options.pattern,
        annotations = options.annotations,
        format = function(item)
            return format_item(item, { show_filename = not options.file })
        end,
        preview = diff_preview.preview,
        matcher = {
            keep_parents = true,
            sort = false,
        },
        actions = actions,
        win = {
            input = {
                keys = keys,
            },
        },
        on_show = function(picker)
            if jump_label_attached[picker] then
                return
            end
            jump_label_attached[picker] = true

            ---@diagnostic disable-next-line: undefined-field
            local matcher_opts = picker.matcher.opts or picker.matcher.options
            local prev_on_done = matcher_opts.on_done
            matcher_opts.on_done = function(matcher)
                if prev_on_done then
                    prev_on_done(matcher)
                end
                picker_util.regroup_by_parent(picker, matcher, not options.file)
                if config.get_picker_config().jump_labels then
                    assign_jump_labels(picker)
                end
            end

            if config.get_picker_config().jump_labels then
                assign_jump_labels(picker)
            end
        end,

        layout = {
            fullscreen = true,
            layout = {
                box = "horizontal",
                width = 0,
                height = 0,
                border = "rounded",
                title = "{title} {live} {flags}",
                {
                    box = "vertical",
                    width = 0.4,
                    { win = "input", height = 1, border = "bottom" },
                    { win = "list", border = "none" },
                },
                {
                    win = "preview",
                    width = 0.6,
                    border = "left",
                    title = "{preview:Diff}",
                    title_pos = "left",
                },
            },
        },
        confirm = function(picker, item)
            if not item then
                picker:close()
                return
            end

            -- Remember whether this file already contained real unsaved work.
            -- Opening it must not inherit a modified flag from picker teardown
            -- or buffer-read side effects.
            local existing_buf = vim.fn.bufnr(item.file)
            local was_modified = existing_buf ~= -1
                and vim.bo[existing_buf].modified

            picker:close()

            if vim.fn.filereadable(item.file) == 0 then
                vim.notify(
                    "big-diff: "
                        .. (item.rel_file or item.file)
                        .. " is not in the working tree",
                    vim.log.levels.WARN
                )
                return
            end

            vim.cmd("edit " .. vim.fn.fnameescape(item.file))
            if not was_modified then
                vim.bo.modified = false
            end
            local line_count = vim.api.nvim_buf_line_count(0)
            local target_line = math.max(1, math.min(item.line, line_count))
            vim.api.nvim_win_set_cursor(0, { target_line, 0 })
        end,
    })
end

---@param path string
---@return boolean
local function path_exists(path)
    if not path or path == "" or not filesystem then
        return false
    end

    if filesystem.fs_stat(path) then
        return true
    end

    local abs = vim.fn.fnamemodify(path, ":p")
    return filesystem.fs_stat(abs) ~= nil
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

---@class GitDiffPickOpts : GitDiffFilterOpts
---@field base? string

---@param options? GitDiffPickOpts
function M.pick(options)
    options = options or {}
    local base = options.base or "HEAD"
    local git_config = config.get_picker_config().git

    if options.ignore_whitespace == nil then
        options.ignore_whitespace = git_config.ignore_whitespace
    end
    if options.group == nil then
        options.group = config.get_picker_config().group
    end

    if options.file and options.file ~= "" then
        options.file = strip_position_suffix(options.file)
    end

    local git_root = options.git_root

    if not git_root and options.file and options.file ~= "" then
        git_root = git_util.find_git_root_for_path(options.file)
    end
    if not git_root then
        git_root = git_util.find_git_root()
    end

    if not git_root then
        vim.notify(
            "Current buffer is not in a git repository",
            vim.log.levels.WARN
        )
        return
    end

    options.git_root = git_root

    git_util.get_diff_hunks(base, options.file, function(_, blocks)
        process_blocks_and_show_picker(options, base, blocks)
    end, {
        git_root = git_root,
        context_lines = git_config.context_lines,
        merge_base = git_config.merge_base,
        include_untracked = git_config.include_untracked,
        detect_staged = true,
        ignore_whitespace = options.ignore_whitespace,
        staged = options.staged,
    })
end

---@param file? string
---@return string?, string?
local function resolve_current_file(file)
    file = file or vim.api.nvim_buf_get_name(0)
    if not file or file == "" then
        return nil, nil
    end

    file = strip_position_suffix(file)

    local git_root = git_util.find_git_root_for_path(file)
        or git_util.find_git_root()
    if not git_root then
        return nil, nil
    end

    return git_util.to_repo_relative_path(file, git_root), git_root
end

---@class GitDiffDefaultBranchOpts : GitDiffFilterOpts
---@field fallback? string

---@param options? GitDiffDefaultBranchOpts
function M.pick_vs_default_branch(options)
    options = options or {}

    if options.file and options.file ~= "" then
        options.file = strip_position_suffix(options.file)
    end

    local git_root = options.git_root
    if not git_root and options.file and options.file ~= "" then
        git_root = git_util.find_git_root_for_path(options.file)
    end
    if not git_root then
        git_root = git_util.find_git_root()
    end

    git_util.get_default_base_branch_async(function(branch)
        M.pick(vim.tbl_extend("force", options, {
            base = branch,
            git_root = git_root,
        }))
    end, { fallback = options.fallback, git_root = git_root })
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

---@param options? GitDiffFilterOpts
function M.pick_vs_head(options)
    options = options or {}
    local resolved, git_root = resolve_current_file()
    M.pick(vim.tbl_extend("force", options, {
        base = "HEAD",
        exclude_file = options.exclude_file or resolved,
        git_root = options.git_root or git_root,
    }))
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

---Only what is in the index: `git diff --cached`.
---@param options? GitDiffFilterOpts
function M.pick_staged(options)
    options = vim.tbl_extend("force", options or {}, { staged = true })
    M.pick(options)
end

---Only what is not staged yet: `git diff`.
---@param options? GitDiffFilterOpts
function M.pick_unstaged(options)
    options = vim.tbl_extend("force", options or {}, { staged = false })
    M.pick(options)
end

return M
