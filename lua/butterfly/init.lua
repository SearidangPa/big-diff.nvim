local M = {}

M.setup = function()
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")

    local function set_hl()
        local file_name_hl = vim.o.background == "dark" and "#3E8FB0"
            or "#276983"
        vim.api.nvim_set_hl(0, "ButterflyFileName", { fg = file_name_hl })
        local dir_name_hl = vim.o.background == "dark" and "#9CCFD9"
            or "#1EAC85"
        vim.api.nvim_set_hl(0, "ButterflyDir", { fg = dir_name_hl })
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

vim.api.nvim_create_user_command("ButterflyDiff", function(opts)
    local split_diff = require("butterfly.split_diff")
    if split_diff.is_open() then
        split_diff.close()
        return
    end

    if opts.args ~= "" then
        split_diff.open(opts.args)
        return
    end

    -- No args: open Snacks picker for branch selection
    Snacks.picker.git_branches({
        all = true,
        confirm = function(picker, item)
            picker:close()
            if item and item.branch then
                split_diff.open(item.branch)
            end
        end,
    })
end, { nargs = "?" })

function M.split_diff()
    local split_diff = require("butterfly.split_diff")
    if split_diff.is_open() then
        split_diff.close()
        return
    end
    require("butterfly.util_git").get_default_base_branch_async(function(branch)
        split_diff.open(branch)
    end)
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
