local M = {}

---@class ButterflyKeymapSpec
---@field mode? string|string[]
---@field lhs string
---@field rhs fun()
---@field opts? table

---@class ButterflySetupOpts
---@field keymaps? ButterflyKeymapSpec[]

---@param opts? ButterflySetupOpts
M.setup = function()
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
