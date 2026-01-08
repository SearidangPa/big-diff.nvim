local M = {}

---@class ButterflyKeymapSpec
---@field mode? string|string[]
---@field lhs string
---@field rhs fun()
---@field opts? table

---@class ButterflySetupOpts
---@field keymaps? ButterflyKeymapSpec[]

---@param opts? ButterflySetupOpts
M.setup = function(opts)
    opts = opts or {}

    -- Side-effect free requires: users control their keymaps.
    require("butterfly.jumplist_fzf")
    require("butterfly.git_diff_fzf")

    if opts.keymaps then
        for _, map in ipairs(opts.keymaps) do
            vim.keymap.set(map.mode or "n", map.lhs, map.rhs, map.opts)
        end
    end
end

---@class ScopeInfo
---@field name string
---@field signature string
---@field kind string

return M
