local M = {}

local default_opts = {
    empty_fallback_len = 8,
    joiner = "_",
    pattern = "[^%s_%-%+%.]+",
}

---@param options? diffhopper.TruncateMiddleOpts
local function normalize_opts(options)
    options = options or {}

    local part_len = options.part_len
    if part_len == nil then
        part_len = 3
        if vim.fn.has("win32") ~= 1 then
            part_len = 4
        end
    end

    return {
        part_len = part_len,
        no_truncate_max = options.no_truncate_max or (3 * part_len),
        empty_fallback_len = options.empty_fallback_len
            or default_opts.empty_fallback_len,
        joiner = options.joiner or default_opts.joiner,
        pattern = options.pattern or default_opts.pattern,
    }
end

---@class diffhopper.TruncateMiddleOpts
---@field part_len? number Number of characters to keep from each part.
---@field no_truncate_max? number Maximum length of string to avoid truncation.
---@field empty_fallback_len? number Number of characters to return when input string has no parts.
---@field joiner? string String used to join parts.
---@field pattern? string Lua pattern used to split the string into parts.

---@param input_string string Input string to truncate.
---@param options? diffhopper.TruncateMiddleOpts Options for truncation.
function M.truncate_middle(input_string, options)
    if type(input_string) ~= "string" then
        return ""
    end

    options = normalize_opts(options)

    if #input_string <= options.no_truncate_max then
        return input_string
    end

    local parts = {}
    for p in input_string:gmatch(options.pattern) do
        parts[#parts + 1] = p
    end

    if #parts == 0 then
        return input_string:sub(1, options.empty_fallback_len)
    end

    if #parts <= 3 then
        for i, p in ipairs(parts) do
            parts[i] = p:sub(1, options.part_len)
        end
        return table.concat(parts, options.joiner)
    end

    local first = parts[1]:sub(1, options.part_len)
    local second = parts[2]:sub(1, options.part_len)
    local second_last = parts[#parts - 1]:sub(1, options.part_len)
    local last = parts[#parts]:sub(1, options.part_len)
    local head = table.concat({ first, second }, options.joiner)
    local tail = table.concat({ second_last, last }, options.joiner)
    return table.concat({ head, tail }, "-")
end

return M
