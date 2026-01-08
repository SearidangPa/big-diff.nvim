local M = {}

M.setup = function()
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
