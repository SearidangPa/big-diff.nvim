local M = {}
local git = require("diffhopper.split_diff.git")
local ui = require("diffhopper.split_diff.ui")
local git_util = require("diffhopper.util_git")

local state = {
    open_next_file = nil,
    open_previous_file = nil,
    buffer_number = nil,
    window_number = nil,
    base = nil,
    files = nil,
    all_files = nil,
    exclude_tests = false,
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
    state.buffer_number = nil
    state.window_number = nil
    state.base = nil
    state.files = nil
    state.all_files = nil
    state.exclude_tests = false
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
    if not (state.buffer_number and state.window_number) then
        return false
    end
    if not vim.api.nvim_buf_is_valid(state.buffer_number) then
        return false
    end
    if not vim.api.nvim_win_is_valid(state.window_number) then
        return false
    end
    return vim.bo[state.buffer_number].filetype == "minidiff"
end

local function is_test_path(file_path)
    return file_path:match("^integration_tests[/\\]")
        or file_path:match("[^%w]integration_tests[/\\]")
        or file_path:match("[/\\]integration_tests[/\\]")
        or file_path:match("_test%.[^/\\]+$")
        or file_path:match("_spec%.lua$")
end

local function apply_file_filter()
    if not state.all_files then
        state.files = nil
        return
    end

    if not state.exclude_tests then
        state.files = state.all_files
        return
    end

    state.files = vim.tbl_filter(function(entry)
        local path = type(entry) == "table" and entry.path or entry
        return not is_test_path(path)
    end, state.all_files)
end

local function render_file_tree()
    apply_file_filter()

    if not (state.base and state.files and state.git_root) then
        return nil
    end

    if not (state.main_win and vim.api.nvim_win_is_valid(state.main_win)) then
        state.main_win = vim.api.nvim_get_current_win()
    end

    local buffer_number, window_number = ui.create_split_buffer()
    state.buffer_number = buffer_number
    state.window_number = window_number

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buffer_number,
        callback = function()
            if state.buffer_number == buffer_number then
                state.buffer_number = nil
                state.window_number = nil
            end
        end,
    })

    local line_to_file_index, apply_line_highlights, highlight_current_file =
        ui.render_files(
            buffer_number,
            window_number,
            state.files,
            state.git_root,
            state.main_win
        )

    local navigation = ui.setup_keymaps(
        buffer_number,
        window_number,
        state.files,
        state.git_root,
        state.main_win,
        state.base,
        line_to_file_index,
        apply_line_highlights,
        highlight_current_file,
        git.open_file_in_main_win,
        function()
            state.exclude_tests = not state.exclude_tests
            M.hide_file_tree()
            local navigation = render_file_tree()
            if navigation then
                navigation.sync_current_file()
            end
            vim.notify(
                state.exclude_tests and "Excluded test files"
                    or "Showing test files",
                vim.log.levels.INFO
            )
        end
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
    state.git_root = git_util.find_git_root(main_buf)
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
    if not require("big-diff.nvim.state").overlay then
        require("big-diff.nvim").toggle_overlay()
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
                and require("big-diff.nvim.state").overlay
            then
                require("big-diff.nvim").toggle_overlay()
            end
            clear_state()
            return
        end

        state.all_files = files
        state.git_root = git_root

        local navigation = render_file_tree()
        if not navigation then
            restore_base_ref()
            restore_main_window_fold_options()
            if
                state.overlay_enabled_by_split_diff
                and require("big-diff.nvim.state").overlay
            then
                require("big-diff.nvim").toggle_overlay()
            end
            clear_state()
            return
        end

        -- Tree creation temporarily selects its window. Restore focus before
        -- the async hunk reads so a concurrent PR refresh does not mistake our
        -- own rendering for the user switching away from the main window.
        vim.api.nvim_set_current_win(state.main_win)
        git.open_file_in_main_win(
            base,
            git_root,
            files[1],
            state.main_win,
            navigation.sync_current_file
        )
    end, { git_root = state.git_root, buffer_number = main_buf })
end

-- A generation token for async clients (e.g. big-diff's cached PR lookup).
-- Opening/closing a view changes it, even when the next view has the same base.
function M.get_session_id()
    return state.session_id
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
    if
        state.window_number and vim.api.nvim_win_is_valid(state.window_number)
    then
        vim.api.nvim_win_close(state.window_number, true)
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

    if
        state.window_number and vim.api.nvim_win_is_valid(state.window_number)
    then
        vim.api.nvim_win_close(state.window_number, true)
    end

    if
        state.overlay_enabled_by_split_diff
        and require("big-diff.nvim.state").overlay
    then
        require("big-diff.nvim").toggle_overlay()
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
