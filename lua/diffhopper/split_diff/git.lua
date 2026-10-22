local M = {}
local git_util = require("diffhopper.util_git")

local function prepare_window_for_hunk_folds(win)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end

    -- Manual folds are required for :fold ranges to take effect.
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldenable = true

    return true
end

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

    -- Create folds closed by default. Users can open them with zR; avoid
    -- recreating them on later visits so their fold state is preserved.
    for _, fold in ipairs(folds) do
        vim.cmd(string.format("%d,%dfold", fold[1], fold[2]))
    end
    vim.cmd("silent! %foldclose!")
end

-- Limit results to the current working directory when it lives inside the
-- repository, so a diff run from a subdirectory does not list sibling changes.
---@param git_root string
---@return string[]
local function cwd_pathspec(git_root)
    local cwd = vim.fn.resolve(vim.fn.getcwd())
    local root = vim.fn.resolve(git_root)
    if cwd == root or not vim.startswith(cwd .. "/", root .. "/") then
        return {}
    end

    return { "--", cwd }
end

---@param options? { git_root?: string, buffer_number?: integer }
function M.get_diff_files(base, callback, options)
    options = options or {}
    local git_root = options.git_root or git_util.find_git_root(options.bufnr)
    if not git_root or git_root == "" then
        vim.schedule(function()
            callback({}, nil)
        end)
        return
    end

    local pathspec = cwd_pathspec(git_root)

    vim.system(
        vim.list_extend(
            { "git", "diff", "--name-status", "-z", base },
            pathspec
        ),
        { text = true, cwd = git_root },
        function(obj)
            local entries = {}
            local fields = vim.split(obj.stdout or "", "\0", {
                plain = true,
                trimempty = true,
            })
            local i = 1
            while i <= #fields do
                local status = fields[i]
                if not status then
                    break
                end
                local code = status:sub(1, 1)
                if code == "R" or code == "C" then
                    local old_path = fields[i + 1]
                    local new_path = fields[i + 2]
                    if new_path then
                        table.insert(entries, {
                            path = new_path,
                            status = code,
                            orig_path = old_path,
                        })
                    end
                    i = i + 3
                else
                    local path = fields[i + 1]
                    if path then
                        table.insert(entries, { path = path, status = code })
                    end
                    i = i + 2
                end
            end

            local seen = {}
            for _, entry in ipairs(entries) do
                seen[entry.path] = true
            end

            vim.system(
                vim.list_extend({
                    "git",
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                    "-z",
                }, pathspec),
                { text = true, cwd = git_root },
                function(list_obj)
                    local list_fields = vim.split(list_obj.stdout or "", "\0", {
                        plain = true,
                        trimempty = true,
                    })
                    for _, path in ipairs(list_fields) do
                        if path ~= "" and not seen[path] then
                            table.insert(entries, {
                                path = path,
                                status = "A",
                                untracked = true,
                            })
                            seen[path] = true
                        end
                    end

                    vim.schedule(function()
                        callback(entries, git_root)
                    end)
                end
            )
        end
    )
end

function M.open_file_in_main_win(base, git_root, entry, main_win, on_open)
    -- A PR cache refresh can replace/close the view while these Git reads run.
    -- Guard file callbacks too, not just the outer changed-files query: an old
    -- hunk result must not steal the buffer/focus from a newer session.
    local split = require("diffhopper.split_diff")
    local session_id = split.get_session_id()
    local function is_current()
        return split.get_session_id() == session_id
            and vim.api.nvim_win_is_valid(main_win)
    end

    local file = entry
    local status = nil
    if type(entry) == "table" then
        file = entry.path
        status = entry.status
    end
    if not file or file == "" then
        return
    end
    if not vim.api.nvim_win_is_valid(main_win) then
        return
    end

    if status == "D" then
        vim.api.nvim_set_current_win(main_win)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(main_win, buf)
        vim.api.nvim_buf_set_name(buf, "diffhopper://deleted/" .. file)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].modifiable = true

        local filetype = vim.filetype.match({ filename = file })
        if filetype then
            vim.bo[buf].filetype = filetype
        end

        vim.system({
            "git",
            "-C",
            git_root,
            "show",
            string.format("%s:%s", base, file),
        }, { text = true }, function(obj)
            local text = obj.stdout or ""
            local lines = vim.split(text, "\n", { plain = true })
            if #lines > 0 and lines[#lines] == "" then
                table.remove(lines, #lines)
            end
            if obj.code ~= 0 then
                lines = { "Deleted file contents unavailable: " .. file }
            end

            vim.schedule(function()
                if not is_current() or not vim.api.nvim_buf_is_valid(buf) then
                    return
                end
                vim.bo[buf].modifiable = true
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
                vim.bo[buf].modifiable = false
                vim.bo[buf].readonly = true
                vim.api.nvim_win_set_cursor(main_win, { 1, 0 })
                vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
                vim.b[buf].diffhopper_diff_path = file
                vim.b[buf].diffhopper_diff_status = status
                vim.wo[main_win].winhl =
                    "Normal:DiffHopperDeleted,NormalNC:DiffHopperDeleted"
                if on_open then
                    on_open()
                end
            end)
        end)
        return
    end

    git_util.get_diff_hunks(base, file, function(hunks)
        if not is_current() then
            return
        end
        git_util.get_diff_hunks(base, file, function(fold_hunks)
            if not is_current() then
                return
            end
            local hunk_line = (hunks[1] and hunks[1].line) or 1
            vim.api.nvim_set_current_win(main_win)
            vim.cmd(
                "noautocmd edit " .. vim.fn.fnameescape(git_root .. "/" .. file)
            )

            vim.api.nvim_exec_autocmds("BufReadPost", { buffer = 0 })
            if vim.api.nvim_win_is_valid(main_win) then
                vim.wo[main_win].winhl = ""
            end
            vim.b.diffhopper_diff_path = file
            vim.b.diffhopper_diff_status = status or "M"

            local line_count = vim.api.nvim_buf_line_count(0)
            local target_line = math.max(1, math.min(hunk_line, line_count))
            -- Recreate folds on every open. :edit/:buffer reloads and other diff
            -- plugins can clear or replace manual folds while buffer variables stay
            -- set, so using a "folds initialized" flag leaves large unchanged
            -- regions unfolded on subsequent visits.
            if not prepare_window_for_hunk_folds(main_win) then
                return
            end
            vim.cmd("silent! normal! zE")
            fold_between_hunks_from_git(#fold_hunks > 0 and fold_hunks or hunks)
            vim.b.diffhopper_split_diff_fold_base = base
            vim.b.diffhopper_split_diff_fold_path = file
            vim.api.nvim_win_set_cursor(0, { target_line, 0 })
            pcall(require("big-diff.nvim").enable, 0)
            if on_open then
                on_open()
            end
        end, { git_root = git_root, ignore_whitespace = true })
    end, { git_root = git_root })
end

return M
