local M = {}

M.setup = function()
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")
    vim.api.nvim_create_user_command("ButterflyDiff", function(opts)
        if opts.args ~= "" then
            require("butterfly.split_diff").open(opts.args)
            return
        end

        require("butterfly.util_git").get_default_base_branch_async(
            function(branch)
                require("butterfly.split_diff").open(branch)
            end
        )
    end, { nargs = "?" })

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

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
