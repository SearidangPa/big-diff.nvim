local M = {}
local git = require("butterfly.split_diff.git")
local ui = require("butterfly.split_diff.ui")

local state = {
    open_next_file = nil,
    open_previous_file = nil,
    bufnr = nil,
    winnr = nil,
    original_base_ref = nil,
    original_base_ref_set = false,
}

local function clear_state()
    state.open_next_file = nil
    state.open_previous_file = nil
    state.bufnr = nil
    state.winnr = nil
    state.original_base_ref = nil
    state.original_base_ref_set = false
end

local function restore_base_ref()
    if not state.original_base_ref_set then
        return
    end
    vim.g.minidiff_git_base_ref = state.original_base_ref
    vim.api.nvim_exec_autocmds("User", { pattern = "MiniDiffRefresh" })
    state.original_base_ref = nil
    state.original_base_ref_set = false
end

function M.open(base)
    assert(base ~= "", "Base ref cannot be an empty string")
    if not state.original_base_ref_set then
        state.original_base_ref = vim.g.minidiff_git_base_ref
        state.original_base_ref_set = true
    end
    vim.g.minidiff_git_base_ref = base
    vim.api.nvim_exec_autocmds("User", { pattern = "MiniDiffRefresh" })
    if not require("big-diff.state").overlay then
        require("big-diff").toggle_overlay()
    end

    git.get_diff_files(base, function(files, git_root)
        if #files == 0 then
            vim.notify("No changes in diff", vim.log.levels.INFO)
            return
        end

        local current_win = vim.api.nvim_get_current_win()
        local bufnr, winnr = ui.create_split_buffer()
        state.bufnr = bufnr
        state.winnr = winnr
        vim.api.nvim_create_autocmd("BufWipeout", {
            buffer = bufnr,
            callback = function()
                if state.bufnr == bufnr then
                    restore_base_ref()
                    clear_state()
                end
            end,
        })
        local line_to_file_index, apply_line_highlights, highlight_current_file =
            ui.render_files(bufnr, winnr, files, git_root, current_win)

        local navigation = ui.setup_keymaps(
            bufnr,
            winnr,
            files,
            git_root,
            current_win,
            base,
            line_to_file_index,
            apply_line_highlights,
            highlight_current_file,
            git.open_file_in_main_win
        )
        state.open_next_file = navigation.open_next_file
        state.open_previous_file = navigation.open_previous_file

        git.open_file_in_main_win(
            base,
            git_root,
            files[1],
            current_win,
            navigation.sync_current_file
        )
    end)
end

function M.is_open()
    if not (state.bufnr and state.winnr) then
        return false
    end
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
        return false
    end
    if not vim.api.nvim_win_is_valid(state.winnr) then
        return false
    end
    return vim.bo[state.bufnr].filetype == "minidiff"
end

function M.close()
    restore_base_ref()
    if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        vim.api.nvim_win_close(state.winnr, true)
    end

    if require("big-diff.state").overlay then
        require("big-diff").toggle_overlay()
    end
    -- clear_state() will be called automatically by the BufWipeout autocmd
end

function M.next_file()
    if state.open_next_file then
        state.open_next_file()
    end
end

function M.previous_file()
    if state.open_previous_file then
        state.open_previous_file()
    end
end

return M
