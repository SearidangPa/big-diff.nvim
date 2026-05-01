local M = {}
local git = require("butterfly.split_diff.git")
local ui = require("butterfly.split_diff.ui")
local util_git = require("butterfly.util_git")

local state = {
    open_next_file = nil,
    open_previous_file = nil,
    bufnr = nil,
    winnr = nil,
    base = nil,
    files = nil,
    git_root = nil,
    main_win = nil,
    original_base_ref = nil,
    original_base_ref_set = false,
    original_foldenable = nil,
    original_foldmethod = nil,
    overlay_enabled_by_split_diff = false,
    first_toggle_done = false,
    session_id = 0,
}

local function clear_state()
    state.open_next_file = nil
    state.open_previous_file = nil
    state.bufnr = nil
    state.winnr = nil
    state.base = nil
    state.files = nil
    state.git_root = nil
    state.main_win = nil
    state.original_base_ref = nil
    state.original_base_ref_set = false
    state.original_foldenable = nil
    state.original_foldmethod = nil
    state.overlay_enabled_by_split_diff = false
    state.first_toggle_done = false
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

local function capture_main_window_fold_options()
    if state.original_foldmethod ~= nil then
        return
    end
    if not (state.main_win and vim.api.nvim_win_is_valid(state.main_win)) then
        return
    end

    state.original_foldmethod = vim.wo[state.main_win].foldmethod
    state.original_foldenable = vim.wo[state.main_win].foldenable
end

local function restore_main_window_fold_options()
    if state.original_foldmethod == nil then
        return
    end

    if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
        vim.wo[state.main_win].foldmethod = state.original_foldmethod
        vim.wo[state.main_win].foldenable = state.original_foldenable
    end

    state.original_foldmethod = nil
    state.original_foldenable = nil
end

local function is_file_tree_visible()
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

local function render_file_tree()
    if not (state.base and state.files and state.git_root) then
        return nil
    end

    if not (state.main_win and vim.api.nvim_win_is_valid(state.main_win)) then
        state.main_win = vim.api.nvim_get_current_win()
    end

    local bufnr, winnr = ui.create_split_buffer()
    state.bufnr = bufnr
    state.winnr = winnr

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
            if state.bufnr == bufnr then
                state.bufnr = nil
                state.winnr = nil
            end
        end,
    })

    local line_to_file_index, apply_line_highlights, highlight_current_file =
        ui.render_files(
            bufnr,
            winnr,
            state.files,
            state.git_root,
            state.main_win
        )

    local navigation = ui.setup_keymaps(
        bufnr,
        winnr,
        state.files,
        state.git_root,
        state.main_win,
        state.base,
        line_to_file_index,
        apply_line_highlights,
        highlight_current_file,
        git.open_file_in_main_win
    )

    state.open_next_file = navigation.open_next_file
    state.open_previous_file = navigation.open_previous_file
    navigation.sync_current_file()

    return navigation
end

function M.open(base)
    assert(base ~= "", "Base ref cannot be an empty string")

    if M.is_open() then
        M.close()
    end

    state.session_id = state.session_id + 1
    local session_id = state.session_id

    state.base = base
    state.main_win = vim.api.nvim_get_current_win()
    local main_buf = vim.api.nvim_win_get_buf(state.main_win)
    state.git_root = util_git.find_git_root(main_buf)
    if not state.git_root then
        vim.notify(
            "Current buffer is not in a git repository",
            vim.log.levels.WARN
        )
        clear_state()
        return
    end
    capture_main_window_fold_options()

    if not state.original_base_ref_set then
        state.original_base_ref = vim.g.minidiff_git_base_ref
        state.original_base_ref_set = true
    end
    vim.g.minidiff_git_base_ref = base
    vim.api.nvim_exec_autocmds("User", { pattern = "MiniDiffRefresh" })
    if not require("big-diff.state").overlay then
        require("big-diff").toggle_overlay()
        state.overlay_enabled_by_split_diff = true
    else
        state.overlay_enabled_by_split_diff = false
    end

    git.get_diff_files(base, function(files, git_root)
        if state.session_id ~= session_id then
            return
        end

        if #files == 0 then
            vim.notify("No changes in diff", vim.log.levels.INFO)
            restore_base_ref()
            restore_main_window_fold_options()
            if
                state.overlay_enabled_by_split_diff
                and require("big-diff.state").overlay
            then
                require("big-diff").toggle_overlay()
            end
            clear_state()
            return
        end

        state.files = files
        state.git_root = git_root

        local navigation = render_file_tree()
        if not navigation then
            restore_base_ref()
            restore_main_window_fold_options()
            if
                state.overlay_enabled_by_split_diff
                and require("big-diff.state").overlay
            then
                require("big-diff").toggle_overlay()
            end
            clear_state()
            return
        end

        git.open_file_in_main_win(
            base,
            git_root,
            files[1],
            state.main_win,
            navigation.sync_current_file
        )
    end, { git_root = state.git_root, bufnr = main_buf })
end

function M.is_open()
    return state.base ~= nil
end

function M.is_file_tree_visible()
    return is_file_tree_visible()
end

function M.show_file_tree()
    if not M.is_open() or is_file_tree_visible() then
        return
    end
    render_file_tree()
    if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
        vim.api.nvim_set_current_win(state.main_win)
    end
end

function M.hide_file_tree()
    if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        vim.api.nvim_win_close(state.winnr, true)
    end
end

function M.toggle_file_tree()
    if is_file_tree_visible() then
        M.hide_file_tree()
        return
    end
    M.show_file_tree()
end

function M.close()
    if not M.is_open() then
        return
    end

    state.session_id = state.session_id + 1

    restore_base_ref()
    restore_main_window_fold_options()

    if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        vim.api.nvim_win_close(state.winnr, true)
    end

    if
        state.overlay_enabled_by_split_diff
        and require("big-diff.state").overlay
    then
        require("big-diff").toggle_overlay()
    end

    clear_state()
end

function M.has_done_first_toggle()
    return state.first_toggle_done
end

function M.mark_first_toggle_done()
    state.first_toggle_done = true
end

function M.unfold_all()
    if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
        vim.api.nvim_win_call(state.main_win, function()
            vim.cmd("normal! zR")
        end)
    end
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
