local M = {}
local truncate = require("diffhopper.util_truncate")

local highlight_ns = vim.api.nvim_create_namespace("MiniDiffHighlight")
local current_line_ns =
    vim.api.nvim_create_namespace("MiniDiffHighlightCurrent")

function M.create_split_buffer()
    vim.cmd("topleft vnew")
    local buffer_number = vim.api.nvim_get_current_buf()
    local window_number = vim.api.nvim_get_current_win()

    -- Buffer options
    vim.bo[buffer_number].buftype = "nofile"
    vim.bo[buffer_number].bufhidden = "wipe"
    vim.bo[buffer_number].swapfile = false
    vim.bo[buffer_number].filetype = "minidiff"

    -- Window options
    vim.wo[window_number].number = false
    vim.wo[window_number].relativenumber = false
    vim.wo[window_number].signcolumn = "no"
    vim.wo[window_number].foldcolumn = "0"
    vim.wo[window_number].winfixwidth = true

    local width = math.floor(vim.o.columns * 0.15)
    vim.api.nvim_win_resize(window_number, width, -1)

    return buffer_number, window_number
end

-- Pin a pill-shaped "tests hidden" badge to the tree's winbar, or clear it
-- when hidden_count is nil.
function M.render_tests_hidden_badge(window_number, hidden_count)
    if hidden_count == nil then
        vim.wo[window_number].winbar = ""
        return
    end

    local label = hidden_count == 1 and "1 test hidden"
        or (hidden_count .. " tests hidden")
    -- Blend the winbar into the tree so the rounded caps sit on its background
    vim.wo[window_number].winhighlight =
        "WinBar:DiffHopperTreeWinBar,WinBarNC:DiffHopperTreeWinBar"
    vim.wo[window_number].winbar = table.concat({
        "%#DiffHopperTestsHiddenCap#\u{E0B6}", -- rounded left cap
        "%#DiffHopperTestsHiddenIcon#\u{F0209} ", -- nf-md-eye_off
        "%#DiffHopperTestsHidden# ",
        label,
        " %#DiffHopperTestsHiddenEndCap#\u{E0B4}", -- rounded right cap
        "%#DiffHopperTreeWinBar#",
    })
end

function M.render_files(buffer_number, window_number, files, git_root, main_win)
    local width = vim.api.nvim_win_get_width(window_number) - 2
    local lines = {}
    local line_to_file_index = {}
    local current_line = nil
    local groups = {}
    local group_names = {}

    local current_buf = vim.api.nvim_get_current_buf()
    if main_win and vim.api.nvim_win_is_valid(main_win) then
        current_buf = vim.api.nvim_win_get_buf(main_win)
    end
    local current_path = nil
    local current_is_diff_path = false
    local ok, diff_path =
        pcall(vim.api.nvim_buf_get_var, current_buf, "diffhopper_diff_path")
    if ok and diff_path and diff_path ~= "" then
        current_path = diff_path
        current_is_diff_path = true
    else
        local current_file = vim.api.nvim_buf_get_name(current_buf)
        if current_file ~= "" then
            current_path = vim.fs.normalize(current_file)
        end
    end

    for i, entry in ipairs(files) do
        local file = type(entry) == "table" and entry.path or entry
        local parent = vim.fn.fnamemodify(file, ":h")
        local group = parent == "." and "." or vim.fn.fnamemodify(parent, ":t")
        if not groups[group] then
            groups[group] = {}
            table.insert(group_names, group)
        end
        table.insert(groups[group], {
            index = i,
            path = file,
            status = entry.status,
            untracked = entry.untracked,
        })
    end

    local highlights = {}

    for _, group in ipairs(group_names) do
        local group_display =
            truncate.truncate_middle(group, { no_truncate_max = width })
        table.insert(lines, group_display)
        line_to_file_index[#lines] = false
        highlights[#lines] = "DiffHopperDir"

        local group_entries = groups[group]
        for entry_index, entry in ipairs(group_entries) do
            local basename = vim.fn.fnamemodify(entry.path, ":t:r")
            local prefix
            if entry_index == #group_entries then
                prefix = "└╴ "
            else
                prefix = "├╴ "
            end

            local max_width = math.max(0, width - #prefix)
            local display_basename = basename
            if basename:find("_", 1, true) then
                display_basename = truncate.truncate_middle(
                    basename,
                    { no_truncate_max = max_width }
                )
            end
            local display = prefix .. display_basename
            table.insert(lines, display)
            line_to_file_index[#lines] = entry.index
            if entry.untracked then
                highlights[#lines] = "DiffHopperUntracked"
            elseif entry.status == "A" then
                highlights[#lines] = "MiniDiffOverAdd"
            else
                highlights[#lines] = "Comment"
            end

            -- Check if this is the current file
            if current_path then
                if current_is_diff_path then
                    if entry.path == current_path then
                        current_line = #lines
                    end
                else
                    local absolute_path =
                        vim.fs.normalize(git_root .. "/" .. entry.path)
                    if
                        vim.fn.resolve(absolute_path)
                        == vim.fn.resolve(current_path)
                    then
                        current_line = #lines
                    end
                end
            end
        end
    end

    vim.bo[buffer_number].modifiable = true
    vim.api.nvim_buf_set_lines(buffer_number, 0, -1, false, lines)
    vim.bo[buffer_number].modifiable = false

    local function apply_line_highlights()
        vim.api.nvim_buf_clear_namespace(buffer_number, highlight_ns, 0, -1)
        for line_nr, hl_group in ipairs(highlights) do
            local line = lines[line_nr] or ""
            vim.api.nvim_buf_set_extmark(
                buffer_number,
                highlight_ns,
                line_nr - 1,
                0,
                {
                    hl_group = hl_group,
                    end_row = line_nr - 1,
                    end_col = #line,
                }
            )
        end
    end

    apply_line_highlights()

    local function highlight_current_file(line_override)
        if line_override == false then
            current_line = nil
            vim.api.nvim_buf_clear_namespace(
                buffer_number,
                current_line_ns,
                0,
                -1
            )
            return
        end
        local highlight_line = line_override or current_line
        if not highlight_line then
            for line_nr, file_index in ipairs(line_to_file_index) do
                if file_index then
                    highlight_line = line_nr
                    break
                end
            end
        end
        if highlight_line then
            current_line = highlight_line
            vim.api.nvim_buf_clear_namespace(
                buffer_number,
                current_line_ns,
                0,
                -1
            )
            vim.api.nvim_buf_set_extmark(
                buffer_number,
                current_line_ns,
                highlight_line - 1,
                0,
                {
                    line_hl_group = "DiffHopperFileName",
                }
            )
        end
    end

    highlight_current_file()

    return line_to_file_index, apply_line_highlights, highlight_current_file
end

function M.setup_keymaps(
    buffer_number,
    window_number,
    files,
    git_root,
    main_win,
    base,
    line_to_file_index,
    apply_line_highlights,
    highlight_current_file,
    open_file_in_main_win,
    toggle_exclude_tests
)
    local open_next_file
    local open_previous_file

    local file_sequence = {}
    local file_sequence_pos = {}
    for _, index in ipairs(line_to_file_index) do
        if index and not file_sequence_pos[index] then
            file_sequence_pos[index] = #file_sequence + 1
            file_sequence[#file_sequence + 1] = index
        end
    end

    local function file_index_to_line(file_index)
        for line_nr, index in ipairs(line_to_file_index) do
            if index == file_index then
                return line_nr
            end
        end
    end

    local function open_file_by_index(file_index)
        local file_entry = file_index and files[file_index]
        if not file_entry then
            return
        end
        if not vim.api.nvim_win_is_valid(main_win) then
            return
        end

        open_file_in_main_win(base, git_root, file_entry, main_win)

        if vim.api.nvim_buf_is_valid(buffer_number) then
            apply_line_highlights()
            local highlight_line = file_index_to_line(file_index)
            if highlight_line then
                highlight_current_file(highlight_line)
            end
        end
    end

    if toggle_exclude_tests then
        vim.keymap.set("n", "<Tab>", toggle_exclude_tests, {
            buffer = buffer_number,
            nowait = true,
            desc = "Toggle test files",
        })
    end

    -- Open file on Enter
    vim.keymap.set("n", "<CR>", function()
        local line_nr = vim.api.nvim_win_get_cursor(0)[1]
        local file_index = line_to_file_index[line_nr]
        open_file_by_index(file_index)
    end, { buffer = buffer_number, nowait = true })

    local function find_current_file_index()
        local current_bufnr = vim.api.nvim_win_get_buf(main_win)
        local ok, diff_path = pcall(
            vim.api.nvim_buf_get_var,
            current_bufnr,
            "diffhopper_diff_path"
        )
        if ok and diff_path and diff_path ~= "" then
            for i, entry in ipairs(files) do
                local entry_path = type(entry) == "table" and entry.path
                    or entry
                if entry_path == diff_path then
                    return i
                end
            end
            return nil
        end
        local current_path = vim.api.nvim_buf_get_name(current_bufnr)
        if current_path == "" then
            return nil
        end
        for i, entry in ipairs(files) do
            local entry_path = type(entry) == "table" and entry.path or entry
            local entry_status = type(entry) == "table" and entry.status or nil
            if entry_status ~= "D" then
                local absolute_path =
                    vim.fs.normalize(git_root .. "/" .. entry_path)
                local normalized_current = vim.fs.normalize(current_path)
                if
                    vim.fn.resolve(absolute_path)
                    == vim.fn.resolve(normalized_current)
                then
                    return i
                end
            end
        end
    end

    local function sync_current_file()
        if not vim.api.nvim_win_is_valid(main_win) then
            return
        end
        if not vim.api.nvim_buf_is_valid(buffer_number) then
            return
        end
        local current_index = find_current_file_index()
        if not current_index then
            highlight_current_file(false)
            return
        end
        local line_nr = file_index_to_line(current_index)
        if line_nr then
            highlight_current_file(line_nr)
            if vim.api.nvim_win_is_valid(window_number) then
                vim.api.nvim_win_set_cursor(window_number, { line_nr, 0 })
            end
        end
    end

    local sync_group = vim.api.nvim_create_augroup(
        "DiffHopperSplitDiffSync" .. buffer_number,
        { clear = true }
    )
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter" }, {
        group = sync_group,
        callback = sync_current_file,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = sync_group,
        buffer = buffer_number,
        callback = function()
            pcall(vim.api.nvim_del_augroup_by_id, sync_group)
        end,
    })

    open_next_file = function()
        if #file_sequence == 0 then
            return
        end

        local current_index = find_current_file_index()
        local pos = current_index and file_sequence_pos[current_index] or nil
        local next_pos = pos and (pos + 1) or 1
        if next_pos > #file_sequence then
            next_pos = 1
        end
        local next_index = file_sequence[next_pos]
        open_file_by_index(next_index)
        local line_nr = file_index_to_line(next_index)
        if line_nr and vim.api.nvim_win_is_valid(window_number) then
            vim.api.nvim_win_set_cursor(window_number, { line_nr, 0 })
        end
    end

    open_previous_file = function()
        if #file_sequence == 0 then
            return
        end

        local current_index = find_current_file_index()
        local pos = current_index and file_sequence_pos[current_index] or nil
        local prev_pos = pos and (pos - 1) or #file_sequence
        if prev_pos < 1 then
            prev_pos = #file_sequence
        end
        local prev_index = file_sequence[prev_pos]
        open_file_by_index(prev_index)
        local line_nr = file_index_to_line(prev_index)
        if line_nr and vim.api.nvim_win_is_valid(window_number) then
            vim.api.nvim_win_set_cursor(window_number, { line_nr, 0 })
        end
    end

    return {
        open_next_file = open_next_file,
        open_previous_file = open_previous_file,
        sync_current_file = sync_current_file,
    }
end

return M
