-- luacheck: globals describe it assert before_each after_each
local ctx = require("butterfly.utils_picker_context")
local jumplist = require("butterfly.jumplist_fzf")
local eq = assert.are.same

describe("utils_picker_context import block", function()
    local tmpdir
    local created_buffers = {}

    local function create_file(name, lines)
        local path = tmpdir .. "/" .. name
        vim.fn.writefile(lines, path)
        local bufnr = vim.fn.bufadd(path)
        table.insert(created_buffers, bufnr)
        return path, bufnr
    end

    before_each(function()
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
    end)

    after_each(function()
        for _, bufnr in ipairs(created_buffers) do
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        created_buffers = {}

        ctx.clear_file_cache()

        if tmpdir and tmpdir ~= "" then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    local LUA_FILE = {
        'local a = require("a")', -- 1
        'local b = require("b")', -- 2
        "", -- 3
        'local c = require("c")', -- 4
        "", -- 5
        "local function alpha()", -- 6
        '  local d = require("d")', -- 7
        "  return d", -- 8
        "end", -- 9
    }

    it("ignores top-level require lines and blanks between them", function()
        local path = create_file("imports.lua", LUA_FILE)

        local results = ctx.batch_get_scopes(
            path,
            { 1, 2, 3, 4, 5, 6, 7, 8 },
            { check_ignored = true }
        )

        eq({ true, true, true, true }, {
            results[1].ignored,
            results[2].ignored,
            results[3].ignored,
            results[4].ignored,
        })

        -- Blank line 5 trails the block (next line is code), and a require
        -- nested inside a function is a real change.
        eq({ false, false, false, false }, {
            results[5].ignored,
            results[6].ignored,
            results[7].ignored,
            results[8].ignored,
        })
    end)

    it("keeps a hunk that starts in imports but spills into code", function()
        local path = create_file("spill.lua", LUA_FILE)

        local _, cache = ctx.batch_get_scopes(path, { 1 }, {})

        eq(true, ctx.is_ignored_range(cache, 1, 4))
        eq(false, ctx.is_ignored_range(cache, 1, 8))
        eq(false, ctx.is_ignored_range(cache, 6, 3))
    end)

    it("drops jumplist entries landing in the import block", function()
        local _, bufnr = create_file("jumps.lua", LUA_FILE)

        local list = {
            { bufnr = bufnr, lnum = 1, col = 1 },
            { bufnr = bufnr, lnum = 4, col = 1 },
            { bufnr = bufnr, lnum = 8, col = 1 },
        }

        local items = jumplist._build_jump_items({}, list, tmpdir, nil)

        eq(2, #items)
        eq(true, items[1].is_header)
        eq(8, items[2].line)
    end)
end)
