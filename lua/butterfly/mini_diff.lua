local M = {}
local truncate = require("butterfly.util_truncate")

local function setup_highlights()
    local cyan = vim.o.background == "dark" and "#35C9EB" or "#276983"
    vim.api.nvim_set_hl(0, "MiniDiffCurrentFile", { fg = cyan, bold = true })
end

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

    -- Width: 25% of total width
    local width = math.floor(vim.o.columns * 0.25)
    vim.api.nvim_win_set_width(winnr, width)

    return bufnr, winnr
end

local function render_files(bufnr, winnr, files, current_file, git_root)
    local width = vim.api.nvim_win_get_width(winnr) - 2
    local lines = {}
    local current_line = nil

    for i, file in ipairs(files) do
        local display =
            truncate.truncate_middle(file, { no_truncate_max = width })
        table.insert(lines, display)

        -- Check if this is the current file
        local abs_path = git_root .. "/" .. file
        if abs_path == current_file then
            current_line = i
        end
    end

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    -- Highlight current file
    if current_line then
        vim.api.nvim_buf_add_highlight(
            bufnr,
            -1,
            "MiniDiffCurrentFile",
            current_line - 1,
            0,
            -1
        )
    end
end

local function setup_keymaps(bufnr, winnr, files, git_root)
    -- Open file on Enter
    vim.keymap.set("n", "<CR>", function()
        local line_nr = vim.api.nvim_win_get_cursor(0)[1]
        local file = files[line_nr]
        if file then
            vim.api.nvim_win_close(winnr, true)
            vim.cmd("edit " .. vim.fn.fnameescape(git_root .. "/" .. file))
        end
    end, { buffer = bufnr, nowait = true })

    -- Close on q
    vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(winnr, true)
    end, { buffer = bufnr, nowait = true })
end

function M.open(base)
    base = base or "HEAD"
    setup_highlights()

    local current_file = vim.fn.expand("%:p")

    get_diff_files(base, function(files, git_root)
        if #files == 0 then
            vim.notify("No changes in diff", vim.log.levels.INFO)
            return
        end

        local bufnr, winnr = create_split_buffer()
        render_files(bufnr, winnr, files, current_file, git_root)
        setup_keymaps(bufnr, winnr, files, git_root)
    end)
end

return M
