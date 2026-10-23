local M = {}

local picker_context = require("diffhopper.utils_picker_context")
local picker_util = require("diffhopper.util_picker")

local jump_label_attached = setmetatable({}, { __mode = "k" })

local EXCLUDED_FILETYPES = { "help", "oil" }
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

---@param absolute_path string
---@param current_working_directory string
---@return boolean
local function is_under_cwd(absolute_path, current_working_directory)
    if
        not absolute_path
        or absolute_path == ""
        or not current_working_directory
        or current_working_directory == ""
    then
        return false
    end

    local abs = vim.fn.fnamemodify(absolute_path, ":p")
    local root = vim.fn.fnamemodify(current_working_directory, ":p")

    abs = abs:gsub("/+$", "")
    root = root:gsub("/+$", "")

    if abs == root then
        return true
    end

    return abs:sub(1, #root + 1) == (root .. "/")
end

---@param buffer_number integer
---@param absolute_path string
---@return boolean
local function is_excluded(buffer_number, absolute_path, exclude_current)
    if not absolute_path or absolute_path == "" then
        return true
    end

    if absolute_path:match("^%a+://") then
        return true
    end

    if buffer_number and buffer_number ~= -1 then
        local filetype = vim.bo[buffer_number].filetype
        if filetype == "oil" or filetype == "help" then
            return true
        end
    end
    if exclude_current then
        local current_buffer_number = vim.api.nvim_get_current_buf()
        if buffer_number == current_buffer_number then
            return true
        end
    end

    return false
end

---@param absolute_path string
---@return string
local function shorten_path(absolute_path)
    local rel = vim.fn.fnamemodify(absolute_path, ":~:.")
    if rel == absolute_path then
        return vim.fn.fnamemodify(absolute_path, ":~")
    end
    return rel
end

local EXTRA_HIGHLIGHTS = {
    ["%f[%w]function%f[%W]"] = "@keyword.function",
    ["%f[%w]function%f[%W]%s+[_%a][_%w]*"] = "@function",
    ["%f[%w]function%f[%W]%s+[_%a][_%w]*%.[_%a][_%w]*"] = "@function",
    ["%f[%w]function%f[%W]%s+[_%a][_%w]*:[_%a][_%w]*"] = "@function.method",
}

local function format_item(item, options)
    options = options or {}
    local formatted_item = picker_context.format_item(item, {
        header_hl_group = "DiffHopperFileName",
        extra_highlights = EXTRA_HIGHLIGHTS,
        show_filename = options.show_filename,
        show_tree = options.show_filename,
    })

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

function M._build_jump_items(
    options,
    list,
    current_working_directory,
    current_buffer_number,
    exclude_current
)
    options = options or {}

    local by_file = {}
    local file_order = {}
    local max_jumps_per_file = options.current_buf_only and nil or 5

    for _, j in ipairs(list) do
        local buffer_number = j.bufnr
        local line = tonumber(j.lnum) or 1
        local col = tonumber(j.col) or 1

        if
            not current_buffer_number
            or buffer_number == current_buffer_number
        then
            local name = ""
            if buffer_number and buffer_number ~= 0 then
                name = vim.fn.bufname(buffer_number)
            end

            if name and name ~= "" then
                local abs = vim.fn.fnamemodify(name, ":p")

                local stat = vim.loop.fs_stat(abs)
                local is_file = stat and stat.type == "file"

                if
                    is_file
                    and not is_excluded(buffer_number, abs, exclude_current)
                    and is_under_cwd(abs, current_working_directory)
                then
                    if not by_file[abs] then
                        by_file[abs] = {}
                        table.insert(file_order, abs)
                    end
                    table.insert(by_file[abs], {
                        buffer_number = buffer_number,
                        line = line,
                        col = col,
                    })
                end
            end
        end
    end

    local items = {}
    local label_actions, label_keys = build_label_actions()

    for _, file in ipairs(file_order) do
        local jumps = by_file[file]

        local filetype, treesitter_language =
            picker_context.resolve_ft_and_lang(file)

        local file_item = {
            file = file,
            is_header = true,
            text = vim.fn.fnamemodify(file, ":t"),
            filetype = filetype,
            treesitter_language = treesitter_language,
        }

        local seen = {}
        local children = {}

        local item_index = #jumps
        while item_index >= 1 do
            local j = jumps[item_index]
            local scope, ignored =
                picker_context.get_scope_at_line(file, j.line, {
                    check_ignored = true,
                    excluded_filetypes = EXCLUDED_FILETYPES,
                })

            -- Prefer de-duping by scope name ("per function"), since jumplist entries
            -- often land multiple times within the same function/method.
            local key = scope and scope.name
                or ("line:" .. tostring(j.line) .. ":" .. tostring(j.col))

            -- `ignored` marks import-block / build-tag lines: never worth a jump entry.
            if not ignored and not seen[key] then
                seen[key] = true

                local context_line = nil
                if not scope then
                    context_line =
                        picker_context.get_context_line(file, j.line, {
                            filter_punctuation = true,
                            excluded_filetypes = EXCLUDED_FILETYPES,
                        })
                end

                local search_text = scope and scope.name or context_line or key
                local text = search_text
                if not options.current_buf_only then
                    text = shorten_path(file) .. " " .. search_text
                end

                table.insert(children, {
                    file = file,
                    line = j.line,
                    col = j.col,
                    pos = { j.line, j.col },
                    scope = scope,
                    context_line = context_line,
                    filetype = filetype,
                    treesitter_language = treesitter_language,
                    text = text,
                    parent = file_item,
                })

                if max_jumps_per_file and #children >= max_jumps_per_file then
                    break
                end
            end

            item_index = item_index - 1
        end

        if max_jumps_per_file and #children > 1 then
            local reversed = {}
            for i = #children, 1, -1 do
                reversed[#reversed + 1] = children[i]
            end
            children = reversed
        end

        if #children > 0 then
            if not options.current_buf_only then
                table.insert(items, file_item)
            end

            children[#children].last = true
            for _, child in ipairs(children) do
                table.insert(items, child)
            end
        end
    end

    return items, label_actions, label_keys
end

---@param options? { current_buf_only?: boolean }
function M.pick(options)
    options = options or {}

    local current_working_directory = vim.fn.getcwd()
    local jump_list = vim.fn.getjumplist()[1] or {}
    local current_buffer_number = options.current_buf_only
            and vim.api.nvim_get_current_buf()
        or nil

    local exclude_current = not options.current_buf_only
    local items, label_actions, label_keys = M._build_jump_items(
        options,
        jump_list,
        current_working_directory,
        current_buffer_number,
        exclude_current
    )
    local navigation_actions, navigation_keys = picker_util.header_navigation()

    Snacks.picker({
        title = "Jumplist (cwd)",
        items = items,
        format = function(item)
            return format_item(item, {
                show_filename = not options.current_buf_only,
            })
        end,
        matcher = {
            keep_parents = true,
            sort = false,
        },
        actions = vim.tbl_extend("error", label_actions, navigation_actions),
        win = {
            input = {
                keys = vim.tbl_extend("error", label_keys, navigation_keys),
            },
        },
        on_show = function(picker)
            if jump_label_attached[picker] then
                return
            end
            jump_label_attached[picker] = true

            local matcher_opts = picker.matcher.opts or picker.matcher.options
            local prev_on_done = matcher_opts.on_done
            matcher_opts.on_done = function(matcher)
                if prev_on_done then
                    prev_on_done(matcher)
                end
                picker_util.regroup_by_parent(
                    picker,
                    matcher,
                    not options.current_buf_only
                )
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
                if item.line then
                    local line = tonumber(item.line) or 1
                    local line_count = vim.api.nvim_buf_line_count(0)
                    if line < 1 then
                        line = 1
                    elseif line > line_count then
                        line = line_count
                    end

                    local col = tonumber(item.col) or 1
                    local line_text = vim.api.nvim_buf_get_lines(
                        0,
                        line - 1,
                        line,
                        false
                    )[1] or ""
                    local max_col = #line_text
                    local col0 = col - 1
                    if col0 < 0 or col0 > max_col then
                        col0 = 0
                    end

                    vim.api.nvim_win_set_cursor(0, { line, col0 })
                end
            end
        end,
    })
end

function M.pick_cwd()
    M.pick()
end

function M.pick_buffer()
    M.pick({ current_buf_only = true })
end

return M
