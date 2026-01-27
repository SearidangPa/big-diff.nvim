local M = {}
local truncate = require("butterfly.util_truncate")

local highlight_ns = vim.api.nvim_create_namespace("MiniDiffHighlight")
local current_line_ns =
    vim.api.nvim_create_namespace("MiniDiffHighlightCurrent")

function M.create_split_buffer()
    vim.cmd("topleft vnew")
    local bufnr = vim.api.nvim_get_current_buf()
    local winnr = vim.api.nvim_get_current_win()

    -- Buffer options
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "minidiff"

    -- Window options
    vim.wo[winnr].number = false
    vim.wo[winnr].relativenumber = false
    vim.wo[winnr].signcolumn = "no"
    vim.wo[winnr].foldcolumn = "0"
    vim.wo[winnr].winfixwidth = true

    local width = math.floor(vim.o.columns * 0.2)
    vim.api.nvim_win_set_width(winnr, width)

    return bufnr, winnr
end

function M.render_files(bufnr, winnr, files, git_root)
    local width = vim.api.nvim_win_get_width(winnr) - 2
    local lines = {}
    local line_to_file_index = {}
    local current_line = nil
    local groups = {}
    local group_names = {}

    for i, file in ipairs(files) do
        local parent = vim.fn.fnamemodify(file, ":h")
        local group = parent == "." and "." or vim.fn.fnamemodify(parent, ":t")
        if not groups[group] then
            groups[group] = {}
            table.insert(group_names, group)
        end
        table.insert(groups[group], { index = i, path = file })
    end

    local highlights = {}

    for _, group in ipairs(group_names) do
        local group_display =
            truncate.truncate_middle(group, { no_truncate_max = width })
        table.insert(lines, group_display)
        line_to_file_index[#lines] = false
        highlights[#lines] = "ButterflyDir"

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
            local display = prefix
                .. truncate.truncate_middle(
                    basename,
                    { no_truncate_max = max_width }
                )
            table.insert(lines, display)
            line_to_file_index[#lines] = entry.index
            highlights[#lines] = "Comment"

            -- Check if this is the current file
            local abs_path = vim.fs.normalize(git_root .. "/" .. entry.path)
            local current_file =
                vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
            local normalized_current = vim.fs.normalize(current_file)
            if
                vim.fn.resolve(abs_path) == vim.fn.resolve(normalized_current)
            then
                current_line = #lines
            end
        end
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local function apply_line_highlights()
        vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)
        for line_nr, hl_group in ipairs(highlights) do
            local line = lines[line_nr] or ""
            vim.api.nvim_buf_set_extmark(bufnr, highlight_ns, line_nr - 1, 0, {
                hl_group = hl_group,
                end_row = line_nr - 1,
                end_col = #line,
            })
        end
    end

    apply_line_highlights()

    local function highlight_current_file(line_override)
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
            vim.api.nvim_buf_clear_namespace(bufnr, current_line_ns, 0, -1)
            vim.api.nvim_buf_set_extmark(
                bufnr,
                current_line_ns,
                highlight_line - 1,
                0,
                {
                    line_hl_group = "ButterflyFileName",
                }
            )
        end
    end

    highlight_current_file()

    return line_to_file_index, apply_line_highlights, highlight_current_file
end

function M.setup_keymaps(
    bufnr,
    winnr,
    files,
    git_root,
    main_win,
    base,
    line_to_file_index,
    apply_line_highlights,
    highlight_current_file,
    open_file_in_main_win
)
    local open_next_file
    local open_previous_file

    local function file_index_to_line(file_index)
        for line_nr, index in ipairs(line_to_file_index) do
            if index == file_index then
                return line_nr
            end
        end
    end

    local function open_file_by_index(file_index)
        local file = file_index and files[file_index]
        if not file then
            return
        end
        if not vim.api.nvim_win_is_valid(main_win) then
            return
        end

        open_file_in_main_win(base, git_root, file, main_win)

        if vim.api.nvim_buf_is_valid(bufnr) then
            apply_line_highlights()
            local highlight_line = file_index_to_line(file_index)
            if highlight_line then
                highlight_current_file(highlight_line)
            end
        end
    end

    -- Open file on Enter
    vim.keymap.set("n", "<CR>", function()
        local line_nr = vim.api.nvim_win_get_cursor(0)[1]
        local file_index = line_to_file_index[line_nr]
        open_file_by_index(file_index)
    end, { buffer = bufnr, nowait = true })

    local function find_current_file_index()
        local current_bufnr = vim.api.nvim_win_get_buf(main_win)
        local current_path = vim.api.nvim_buf_get_name(current_bufnr)
        if current_path == "" then
            return nil
        end
        for i, file in ipairs(files) do
            if current_path == git_root .. "/" .. file then
                return i
            end
        end
    end

    open_next_file = function()
        local current_index = find_current_file_index()
        local next_index = current_index and current_index + 1 or 1
        if next_index > #files then
            next_index = 1
        end
        open_file_by_index(next_index)
        local line_nr = file_index_to_line(next_index)
        if line_nr and vim.api.nvim_win_is_valid(winnr) then
            vim.api.nvim_win_set_cursor(winnr, { line_nr, 0 })
        end
    end

    open_previous_file = function()
        local current_index = find_current_file_index()
        local prev_index = current_index and current_index - 1 or #files
        if prev_index < 1 then
            prev_index = #files
        end
        open_file_by_index(prev_index)
        local line_nr = file_index_to_line(prev_index)
        if line_nr and vim.api.nvim_win_is_valid(winnr) then
            vim.api.nvim_win_set_cursor(winnr, { line_nr, 0 })
        end
    end

    return {
        open_next_file = open_next_file,
        open_previous_file = open_previous_file,
    }
end

return M
