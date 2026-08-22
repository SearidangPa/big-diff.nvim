local M = {}

function M.regroup_by_parent(picker, matcher, show_headers)
    if not picker or picker.closed then
        return
    end

    if matcher:empty() then
        return
    end

    local source_items = picker.finder.items or {}
    if #source_items == 0 then
        return
    end

    ---@class DiffHopperPickerGroup
    ---@field parent table|nil
    ---@field items table[]
    ---@field score number
    ---@field min_idx number -- earliest source index for stable sorting

    ---@type table<any, DiffHopperPickerGroup>
    local groups = {}
    ---@type DiffHopperPickerGroup[]
    local group_list = {}

    local function ensure_group(key, parent, item_index)
        local group = groups[key]
        if not group then
            group = {
                parent = parent,
                items = {},
                score = 0,
                min_idx = item_index or math.huge,
            }
            groups[key] = group
            group_list[#group_list + 1] = group
        elseif item_index and item_index < group.min_idx then
            group.min_idx = item_index
        end
        return group
    end

    for _, item in ipairs(source_items) do
        if item.match_tick == matcher.tick and (item.score or 0) > 0 then
            local parent = item.is_header and item or item.parent
            local key = parent or item
            local group = ensure_group(key, parent, item.idx)
            if not item.is_header then
                group.items[#group.items + 1] = item
            end
            if item.score and item.score > group.score then
                group.score = item.score
            end
        end
    end

    if #group_list == 0 then
        return
    end

    for _, group in ipairs(group_list) do
        table.sort(group.items, function(a, b)
            if a.score ~= b.score then
                return a.score > b.score
            end
            return (a.idx or 0) < (b.idx or 0)
        end)
        for _, child in ipairs(group.items) do
            child.last = false
        end
        if #group.items > 0 then
            group.items[#group.items].last = true
        end
    end

    table.sort(group_list, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.min_idx < b.min_idx
    end)

    local new_items = {}
    for _, group in ipairs(group_list) do
        if show_headers and group.parent and group.parent.is_header then
            new_items[#new_items + 1] = group.parent
        end
        for _, child in ipairs(group.items) do
            new_items[#new_items + 1] = child
        end
    end

    picker.list.topk:clear()
    picker.list.items = new_items
    picker.list.top = 1
    if #new_items == 0 then
        picker.list.cursor = 1
    else
        picker.list.cursor = math.min(picker.list.cursor or 1, #new_items)
    end
    picker.list.dirty = true
    picker.list:update({ force = true })
end

return M
