local M = {}
local truncate = require("butterfly.util_truncate")
local util_git = require("butterfly.util_git")

local highlight_ns = vim.api.nvim_create_namespace("MiniDiffHighlight")

local function get_diff_files(base, callback)
    local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
    vim.system(
        { "git", "diff", "--name-only", base },
        { text = true, cwd = git_root },
        function(obj)
            local files = {}
            for line in (obj.stdout or ""):gmatch("[^\n]+") do
                table.insert(files, line)
            end
            vim.schedule(function()
                callback(files, git_root)
            end)
        end
    )
end

local function create_split_buffer()
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

local function render_files(bufnr, winnr, files, current_file, git_root)
    local width = vim.api.nvim_win_get_width(winnr) - 2
    local lines = {}
    local line_to_file = {}
    local current_line = nil
    local groups = {}
    local group_order = {}

    for i, file in ipairs(files) do
        local parent = vim.fn.fnamemodify(file, ":h")
        local group = parent == "." and "." or vim.fn.fnamemodify(parent, ":t")
        if not groups[group] then
            groups[group] = {}
            table.insert(group_order, group)
        end
        table.insert(groups[group], { index = i, path = file })
    end

    local highlights = {}

    for _, group in ipairs(group_order) do
        local group_display =
            truncate.truncate_middle(group, { no_truncate_max = width })
        table.insert(lines, group_display)
        line_to_file[#lines] = false
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
            line_to_file[#lines] = entry.index
            highlights[#lines] = "Comment"

            -- Check if this is the current file
            local abs_path = git_root .. "/" .. entry.path
            if abs_path == current_file then
                current_line = #lines
            end
        end
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    for line_nr, hl_group in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(
            bufnr,
            highlight_ns,
            hl_group,
            line_nr - 1,
            0,
            -1
        )
    end

    -- Highlight current file (default to first file line)
    local highlight_line = current_line
    if not highlight_line then
        for line_nr, file_index in ipairs(line_to_file) do
            if file_index then
                highlight_line = line_nr
                break
            end
        end
    end
    if highlight_line then
        vim.api.nvim_buf_set_extmark(
            bufnr,
            highlight_ns,
            highlight_line - 1,
            0,
            {
                line_hl_group = "ButterflyFileName",
            }
        )
    end

    return line_to_file
end

local function setup_keymaps(
    bufnr,
    winnr,
    files,
    git_root,
    main_win,
    base,
    line_to_file
)
    local open_next_file

    local function set_main_tab_map(target_bufnr)
        if not (target_bufnr and vim.api.nvim_buf_is_valid(target_bufnr)) then
            return
        end
        vim.keymap.set("n", "<Tab>", function()
            if open_next_file then
                open_next_file()
            end
        end, { buffer = target_bufnr, nowait = true })
    end

    local function attach_main_tab_map()
        if not vim.api.nvim_win_is_valid(main_win) then
            return
        end
        set_main_tab_map(vim.api.nvim_win_get_buf(main_win))
    end

    local function file_index_to_line(file_index)
        for line_nr, index in ipairs(line_to_file) do
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
        util_git.get_diff_hunks(base, file, function(hunks)
            local hunk_line = (hunks[1] and hunks[1].line) or 1
            vim.api.nvim_set_current_win(main_win)
            vim.cmd("edit " .. vim.fn.fnameescape(git_root .. "/" .. file))
            local line_count = vim.api.nvim_buf_line_count(0)
            local target_line = math.max(1, math.min(hunk_line, line_count))
            vim.api.nvim_win_set_cursor(0, { target_line, 0 })
        end)
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)
            local highlight_line = file_index_to_line(file_index)
            if highlight_line then
                vim.api.nvim_buf_set_extmark(bufnr, highlight_ns, highlight_line - 1, 0, {
                    line_hl_group = "ButterflyFileName",
                })
            end
        end
    end

    local function open_file_at(line_nr)
        local file_index = line_to_file[line_nr]
        open_file_by_index(file_index)
    end

    -- Open file on Enter
    vim.keymap.set("n", "<CR>", function()
        local line_nr = vim.api.nvim_win_get_cursor(0)[1]
        open_file_at(line_nr)
    end, { buffer = bufnr, nowait = true })

    -- Next file on Tab
    vim.keymap.set("n", "<Tab>", function()
        local start_line = vim.api.nvim_win_get_cursor(0)[1]
        local next_line = nil
        for i = start_line + 1, #line_to_file do
            if line_to_file[i] then
                next_line = i
                break
            end
        end
        if not next_line then
            for i = 1, start_line do
                if line_to_file[i] then
                    next_line = i
                    break
                end
            end
        end
        if next_line then
            vim.api.nvim_win_set_cursor(0, { next_line, 0 })
            open_file_at(next_line)
        end
    end, { buffer = bufnr, nowait = true })

    if vim.api.nvim_win_is_valid(main_win) then
        attach_main_tab_map()
        vim.api.nvim_create_autocmd("BufEnter", {
            callback = function()
                attach_main_tab_map()
            end,
        })
    end

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

    -- Close on q
    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(winnr, true)
    end, { buffer = bufnr, nowait = true })

    return open_next_file
end

function M.open(base)
    base = base or "HEAD"

    local current_file = vim.fn.expand("%:p")

    get_diff_files(base, function(files, git_root)
        if #files == 0 then
            vim.notify("No changes in diff", vim.log.levels.INFO)
            return
        end

        local current_win = vim.api.nvim_get_current_win()
        local bufnr, winnr = create_split_buffer()
        local line_to_file =
            render_files(bufnr, winnr, files, current_file, git_root)
        setup_keymaps(
            bufnr,
            winnr,
            files,
            git_root,
            current_win,
            base,
            line_to_file
        )

        local first_file = git_root .. "/" .. files[1]
        util_git.get_diff_hunks(base, files[1], function(hunks)
            local hunk_line = (hunks[1] and hunks[1].line) or 1
            vim.api.nvim_set_current_win(current_win)
            vim.cmd("edit " .. vim.fn.fnameescape(first_file))
            local line_count = vim.api.nvim_buf_line_count(0)
            local target_line = math.max(1, math.min(hunk_line, line_count))
            vim.api.nvim_win_set_cursor(0, { target_line, 0 })
        end)
    end)
end

return M
