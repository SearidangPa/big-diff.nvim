local M = {}

M.setup = function()
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")
    vim.api.nvim_create_user_command("MiniDiff", function(opts)
        local base = opts.args ~= "" and opts.args or nil
        require("butterfly.mini_diff").open(base)
    end, { nargs = "?" })

    local file_name_hl = vim.o.background == "dark" and "#3E8FB0" or "#276983"
    vim.api.nvim_set_hl(
        0,
        "ButterflyFileName",
        { fg = file_name_hl, bold = true }
    )
    vim.api.nvim_set_hl(0, "ButterflyDir", { fg = "#9CCFD9" })
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
