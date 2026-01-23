local M = {}

M.setup = function()
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")
end

vim.api.nvim_create_user_command("MiniDiff", function(opts)
    local base = opts.args ~= "" and opts.args or nil
    require("butterfly.butterfly").open(base)
end, { nargs = "?" })

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
