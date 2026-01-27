local M = {}
local util_git = require("butterfly.util_git")

-- Fold non-hunk regions. hunks = { { line = N, count = M }, ... }
local function fold_between_hunks_from_git(hunks, context)
    context = context or 2
    if #hunks == 0 then
        return
    end

    -- Sort hunks and merge contiguous/overlapping ones into ranges
    table.sort(hunks, function(a, b)
        return a.line < b.line
    end)
    local ranges = {}
    for _, h in ipairs(hunks) do
        local h_from = h.line
        local h_to = h.line + math.max(h.count - 1, 0)
        if #ranges == 0 or h_from > ranges[#ranges].to + 1 then
            table.insert(ranges, { from = h_from, to = h_to })
        else
            ranges[#ranges].to = math.max(ranges[#ranges].to, h_to)
        end
    end

    local line_count = vim.api.nvim_buf_line_count(0)
    local folds = {}

    -- Fold from start to first hunk (minus context)
    local first_fold_end = ranges[1].from - context - 1
    if first_fold_end >= 1 then
        table.insert(folds, { 1, first_fold_end })
    end

    -- Fold between consecutive hunks
    for i = 1, #ranges - 1 do
        local fold_start = ranges[i].to + context + 1
        local fold_end = ranges[i + 1].from - context - 1
        if fold_start <= fold_end then
            table.insert(folds, { fold_start, fold_end })
        end
    end

    -- Fold from last hunk (plus context) to end
    local last_fold_start = ranges[#ranges].to + context + 1
    if last_fold_start <= line_count then
        table.insert(folds, { last_fold_start, line_count })
    end

    -- Create folds
    for _, fold in ipairs(folds) do
        vim.cmd(string.format("%d,%dfold", fold[1], fold[2]))
    end
end

function M.get_diff_files(base, callback)
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

function M.open_file_in_main_win(base, git_root, file, main_win)
    if not file then
        return
    end
    if not vim.api.nvim_win_is_valid(main_win) then
        return
    end
    util_git.get_diff_hunks(base, file, function(hunks)
        local hunk_line = (hunks[1] and hunks[1].line) or 1
        vim.api.nvim_set_current_win(main_win)
        vim.cmd(
            "noautocmd edit " .. vim.fn.fnameescape(git_root .. "/" .. file)
        )

        vim.api.nvim_exec_autocmds("BufReadPost", { buffer = 0 })

        local line_count = vim.api.nvim_buf_line_count(0)
        local target_line = math.max(1, math.min(hunk_line, line_count))
        fold_between_hunks_from_git(hunks)
        vim.api.nvim_win_set_cursor(0, { target_line, 0 })
        require("mini.diff").enable(0)
    end)
end

return M
