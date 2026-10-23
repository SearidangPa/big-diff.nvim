local M = {}
local DEFAULT_BASE = {}
local LAST_COMMIT = {}

---@param options? table see `diffhopper.config`
M.setup = function(user_options)
    require("diffhopper.config").setup(user_options)
    require("diffhopper.jumplist_fzf")
    require("diffhopper.git_diff_fzf")

    local function set_hl()
        local function hi_overlay(group, options)
            vim.api.nvim_set_hl(0, group, options)
        end

        local file_name_hl = vim.o.background == "dark" and "#3E8FB0"
            or "#276983"
        vim.api.nvim_set_hl(0, "DiffHopperFileName", { fg = file_name_hl })
        local dir_name_hl = vim.o.background == "dark" and "#9CCFD9"
            or "#1EAC85"
        vim.api.nvim_set_hl(0, "DiffHopperDir", { fg = dir_name_hl })

        local is_dark = vim.o.background == "dark"
        if is_dark then
            hi_overlay("MiniDiffOverAdd", { bg = "#243d2a" })
            hi_overlay("MiniDiffOverDelete", { bg = "#3d2022" })
            hi_overlay("MiniDiffOverContext", { bg = "#3a2426" })
            hi_overlay("MiniDiffOverContextBuf", { bg = "#1f3326" })
            hi_overlay("MiniDiffOverChange", { bg = "#330011" })
            hi_overlay("MiniDiffOverChangeBuf", { bg = "#2f3d22" })
            vim.api.nvim_set_hl(0, "DiffHopperUntracked", { bg = "#4F4626" })
        else
            hi_overlay("MiniDiffOverAdd", { bg = "#dafbe1" })
            hi_overlay("MiniDiffOverDelete", { bg = "#FFE0E0" })
            vim.api.nvim_set_hl(0, "DiffHopperUntracked", { bg = "#FEFEF9" })
        end

        vim.api.nvim_set_hl(
            0,
            "DiffHopperDeleted",
            { link = "MiniDiffOverDelete" }
        )

        -- "Tests hidden" badge in the split diff file tree
        local badge_accent = is_dark and "#f6c177" or "#ea9d34"
        local badge_body = is_dark and "#26233a" or "#f2e9e1"
        local badge_ink = is_dark and "#191724" or "#faf4ed"
        vim.api.nvim_set_hl(0, "DiffHopperTreeWinBar", { link = "Normal" })
        vim.api.nvim_set_hl(
            0,
            "DiffHopperTestsHiddenCap",
            { fg = badge_accent }
        )
        vim.api.nvim_set_hl(
            0,
            "DiffHopperTestsHiddenIcon",
            { fg = badge_ink, bg = badge_accent, bold = true }
        )
        vim.api.nvim_set_hl(
            0,
            "DiffHopperTestsHidden",
            { fg = badge_accent, bg = badge_body, bold = true }
        )
        vim.api.nvim_set_hl(
            0,
            "DiffHopperTestsHiddenEndCap",
            { fg = badge_body }
        )

        pcall(require("diffhopper.diff_render").set_hl)
    end

    set_hl()

    vim.api.nvim_create_autocmd({ "ColorScheme" }, {
        callback = function(args)
            if args.event == "OptionSet" and args.match ~= "background" then
                return
            end
            set_hl()
        end,
    })
end

local function handle_open_split_diff(split_diff)
    if not split_diff.is_open() then
        return false
    end

    if not split_diff.has_done_first_toggle() then
        split_diff.mark_first_toggle_done()
        split_diff.hide_file_tree()
    elseif not split_diff.is_file_tree_visible() then
        split_diff.show_file_tree()
    else
        split_diff.close()
    end

    return true
end

---Resolves the parent of HEAD so the split diff shows the latest commit.
---@param split_diff table
local function open_last_commit(split_diff)
    local git_root = require("diffhopper.util_git").find_git_root()
    vim.system({
        "git",
        "-C",
        git_root or ".",
        "rev-parse",
        "--verify",
        "--quiet",
        "HEAD~1",
    }, { text = true }, function(obj)
        local sha = vim.trim(obj.stdout or "")
        vim.schedule(function()
            if obj.code ~= 0 or sha == "" then
                vim.notify(
                    "No previous commit to diff the latest commit against",
                    vim.log.levels.WARN
                )
                return
            end
            split_diff.open(sha)
        end)
    end)
end

local function toggle_split_diff(target)
    local split_diff = require("diffhopper.split_diff")
    if handle_open_split_diff(split_diff) then
        return
    end

    if target == nil then
        Snacks.picker.git_branches({
            all = true,
            confirm = function(picker, item)
                picker:close()
                if item and item.branch then
                    split_diff.open(item.branch)
                end
            end,
        })
        return
    end

    if target == LAST_COMMIT then
        open_last_commit(split_diff)
        return
    end

    if target == DEFAULT_BASE then
        require("diffhopper.util_git").get_default_base_branch_async(
            function(branch)
                split_diff.open(branch)
            end
        )
        return
    end

    split_diff.open(target)
end

vim.api.nvim_create_user_command("DiffHopper", function(options)
    toggle_split_diff(options.args ~= "" and options.args or nil)
end, { nargs = "?" })

function M.split_diff_main()
    toggle_split_diff(DEFAULT_BASE)
end

function M.split_diff()
    toggle_split_diff("HEAD")
end

function M.split_diff_last_commit()
    toggle_split_diff(LAST_COMMIT)
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
