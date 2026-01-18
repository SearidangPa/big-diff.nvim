-- luacheck: globals describe it assert
local util_picker = require("butterfly.util_picker")
local eq = assert.are.same

describe("util_picker.regroup_by_parent", function()
    local function make_matcher(tick)
        return {
            tick = tick,
            empty = function()
                return false
            end,
        }
    end

    local function make_picker(source_items, cursor)
        local cleared = false
        local updated = nil
        local list = {
            items = {},
            cursor = cursor,
            top = 0,
            dirty = false,
            topk = {
                clear = function()
                    cleared = true
                end,
            },
        }
        function list:update(opts)
            updated = opts
        end
        return {
            picker = {
                closed = false,
                finder = { items = source_items },
                list = list,
            },
            list = list,
            cleared = function()
                return cleared
            end,
            updated = function()
                return updated
            end,
        }
    end

    it("regroups by parent and sorts by score", function()
        local matcher = make_matcher(3)

        local header_a = { is_header = true, score = 1, match_tick = 3, idx = 2 }
        local header_b = { is_header = true, score = 1, match_tick = 3, idx = 1 }

        local child_a1 = {
            parent = header_a,
            score = 2,
            match_tick = 3,
            idx = 2,
        }
        local child_a2 = {
            parent = header_a,
            score = 2,
            match_tick = 3,
            idx = 1,
        }
        local child_b1 = {
            parent = header_b,
            score = 5,
            match_tick = 3,
            idx = 4,
        }
        local ignored = {
            parent = header_b,
            score = 0,
            match_tick = 3,
            idx = 5,
        }

        local ctx = make_picker(
            { header_a, header_b, child_a1, child_a2, child_b1, ignored },
            3
        )

        util_picker.regroup_by_parent(ctx.picker, matcher, true)

        eq(
            { header_b, child_b1, header_a, child_a2, child_a1 },
            ctx.list.items
        )
        eq(true, child_b1.last)
        eq(false, child_a2.last)
        eq(true, child_a1.last)
        eq(1, ctx.list.top)
        eq(3, ctx.list.cursor)
        eq(true, ctx.list.dirty)
        eq(true, ctx.cleared())
        eq({ force = true }, ctx.updated())
    end)

    it("skips headers when disabled", function()
        local matcher = make_matcher(4)

        local header_a = { is_header = true, score = 1, match_tick = 4, idx = 2 }
        local header_b = { is_header = true, score = 1, match_tick = 4, idx = 1 }

        local child_a1 = {
            parent = header_a,
            score = 4,
            match_tick = 4,
            idx = 2,
        }
        local child_b1 = {
            parent = header_b,
            score = 6,
            match_tick = 4,
            idx = 1,
        }

        local ctx =
            make_picker({ header_a, header_b, child_a1, child_b1 }, 10)

        util_picker.regroup_by_parent(ctx.picker, matcher, false)

        eq({ child_b1, child_a1 }, ctx.list.items)
        eq(2, ctx.list.cursor)
    end)
end)
