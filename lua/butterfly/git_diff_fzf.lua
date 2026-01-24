local M = {}

local ctx = require("butterfly.utils_picker_context")
local util_git = require("butterfly.util_git")
local util_picker = require("butterfly.util_picker")

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
            virt_text = { { item.jump_label, "SnacksPickerLabel" } },
            virt_text_pos = "right_align",
            hl_mode = "combine",
        }
    end

    return ret
end

---Process hunks and display picker (core logic extracted for reuse)
---@param opts { exclude_tests?: boolean, only_tests?: boolean, file?: string }
---@param base string
---@param hunks table[]
local function process_hunks_and_show_picker(opts, base, hunks)
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
    local label_actions, label_keys = build_label_actions()

    for _, file in ipairs(file_order) do
        local file_hunks = by_file[file]

        -- Batch: collect all line numbers for this file
        local lines = {}
        for _, hunk in ipairs(file_hunks) do
            lines[#lines + 1] = hunk.line
        end

        -- Single batch call: get all scopes + file cache (parses treesitter once)
        local scope_results, file_cache =
            ctx.batch_get_scopes(file, lines, { check_ignored = true })

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
                local key = scope and scope.name
                    or ("line:" .. tostring(hunk.line))

                if not seen[key] then
                    seen[key] = true
                    non_import_children = non_import_children + 1

                    local context_line = nil
                    if not scope then
                        context_line =
                            ctx.get_context_line(hunk.file, hunk.line)
                    end

                    local search_text = scope and scope.name
                        or context_line
                        or key

                    table.insert(children, {
                        file = hunk.file,
                        line = hunk.line,
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
            if picker._jump_label_attached then
                return
            end
            picker._jump_label_attached = true

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
            layout = {
                box = "horizontal",
                width = vim.o.columns,
                height = 0.7,
                border = "rounded",
                title = "{title} {live} {flags}",
                {
                    box = "vertical",
                    width = vim.o.columns,
                    { win = "input", height = 1, border = "bottom" },
                    { win = "list", border = "none" },
                },
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

---@param opts? { base?: string, file?: string, exclude_tests?: boolean, only_tests?: boolean }
function M.pick(opts)
    opts = opts or {}
    local base = opts.base or "HEAD"

    util_git.get_diff_hunks(base, opts.file, function(hunks)
        process_hunks_and_show_picker(opts, base, hunks)
    end)
end

---@param file? string
---@return string?
local function resolve_current_file(file)
    file = file or vim.fn.expand("%")
    if not file or file == "" then
        return nil
    end
    return file
end

---@param opts? { file?: string, exclude_tests?: boolean, only_tests?: boolean, fallback?: string }
function M.pick_vs_default_branch(opts)
    opts = opts or {}
    util_git.get_default_base_branch_async(function(branch)
        M.pick({
            base = branch,
            file = opts.file,
            exclude_tests = opts.exclude_tests,
            only_tests = opts.only_tests,
        })
    end, { fallback = opts.fallback })
end

function M.pick_tests_vs_default_branch()
    M.pick_vs_default_branch({ only_tests = true })
end

function M.pick_context_vs_default_branch()
    M.pick_vs_default_branch({ exclude_tests = true })
end

---@param file? string
function M.pick_file_vs_default_branch(file)
    local resolved = resolve_current_file(file)
    if not resolved then
        vim.notify("No file in current buffer", vim.log.levels.WARN)
        return
    end

    M.pick_vs_default_branch({ file = resolved })
end

---@param opts? { file?: string, exclude_tests?: boolean, only_tests?: boolean }
function M.pick_vs_head(opts)
    opts = opts or {}
    M.pick({
        base = "HEAD",
        file = opts.file,
        exclude_tests = opts.exclude_tests,
        only_tests = opts.only_tests,
    })
end

---@param file? string
function M.pick_file_vs_head(file)
    local resolved = resolve_current_file(file)
    if not resolved then
        vim.notify("No file in current buffer", vim.log.levels.WARN)
        return
    end

    M.pick_vs_head({ file = resolved })
end

return M
