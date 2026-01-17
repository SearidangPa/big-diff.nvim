-- luacheck: globals describe it assert before_each after_each
local jumplist = require("butterfly.jumplist_fzf")
local ctx = require("butterfly.utils_picker_context")
local eq = assert.are.same

describe("jumplist_fzf", function()
    local tmpdir
    local original = {}
    local created_buffers = {}

    local function create_file(name, lines)
        local path = tmpdir .. "/" .. name
        vim.fn.writefile(lines or { "" }, path)
        local bufnr = vim.fn.bufadd(path)
        table.insert(created_buffers, bufnr)
        return path, bufnr
    end

    before_each(function()
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")

        original.resolve_ft_and_lang = ctx.resolve_ft_and_lang
        original.get_scope_at_line = ctx.get_scope_at_line
        original.get_context_line = ctx.get_context_line

        ctx.resolve_ft_and_lang = function()
            return "lua", "lua"
        end
        ctx.get_scope_at_line = function()
            return nil
        end
        ctx.get_context_line = function()
            return "context"
        end
    end)

    after_each(function()
        ctx.resolve_ft_and_lang = original.resolve_ft_and_lang
        ctx.get_scope_at_line = original.get_scope_at_line
        ctx.get_context_line = original.get_context_line

        for _, bufnr in ipairs(created_buffers) do
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        created_buffers = {}

        if tmpdir and tmpdir ~= "" then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    it("orders and caps jumps per file", function()
        local path, bufnr = create_file("one.lua", { "local a = 1" })
        local list = {}
        for i = 1, 7 do
            list[#list + 1] = { bufnr = bufnr, lnum = i, col = 1 }
        end

        local items = jumplist._build_jump_items({}, list, tmpdir, nil)

        eq(6, #items)
        eq(true, items[1].is_header)
        eq(path, items[1].file)

        local lines = {}
        for i = 2, #items do
            lines[#lines + 1] = items[i].line
        end
        eq({ 3, 4, 5, 6, 7 }, lines)
        eq(true, items[#items].last)
    end)
end)
