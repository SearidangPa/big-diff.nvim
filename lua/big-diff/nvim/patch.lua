---Unified/combined diff parser.
---
---Handles everything `git diff` can emit: normal diffs, combined (`--cc`)
---conflict diffs, renames/copies, mode changes, binary blocks and
---`/dev/null` sides for added/deleted files.
local M = {}

---@class BigDiffPos
---@field line number
---@field count number

---@class BigDiffHunk
---@field diff string[] hunk header followed by the hunk body
---@field line number first line on the right (new) side
---@field count number number of lines on the right side
---@field change_line number first *changed* line on the right side
---@field change_count number changed lines on the right side
---@field changes BigDiffPos[] contiguous changed ranges on the right side
---@field context? string git's own `@@ ... @@ func()` trailer
---@field left BigDiffPos old (normal) / ours (merge)
---@field right BigDiffPos new (normal) / working (merge)
---@field parents? BigDiffPos[] theirs (merge)

---@class BigDiffBlock
---@field file string
---@field left? string
---@field right? string
---@field header string[]
---@field hunks BigDiffHunk[]
---@field binary? boolean
---@field unmerged? boolean
---@field untracked? boolean
---@field staged? boolean
---@field mode? { from?: string, to?: string }
---@field rename? { from?: string, to?: string }
---@field copy? { from?: string, to?: string }
---@field new? string mode of the added file
---@field delete? string mode of the deleted file
---@field similarity? number
---@field dissimilarity? number
---@field index? { from: string, to: string, mode?: string }

---@class BigDiffDiff
---@field header string[]
---@field blocks BigDiffBlock[]

local PATH_PREFIXES = { "a", "b", "i", "w", "c", "o", "old", "new" }

---@param file? string
---@param strip_prefix? boolean
---@return string?
local function normalize_diff_path(file, strip_prefix)
    if not file then
        return nil
    end

    file = file:gsub("\t.*$", "")
    file = file:gsub('^"(.-)"$', "%1")

    if file == "/dev/null" then
        return nil
    end

    if strip_prefix == false then
        return file
    end

    for _, prefix in ipairs(PATH_PREFIXES) do
        if file:sub(1, #prefix + 1) == prefix .. "/" then
            return file:sub(#prefix + 2)
        end
    end

    return file
end

M.normalize_diff_path = normalize_diff_path

---Parses `@@ -a,b +c,d @@ context` and the combined `@@@ ... @@@` form.
---@param line string
---@return BigDiffHunk?
function M.parse_hunk_header(line)
    local open, inner, close, context =
        line:match("^(@+)%s*(.-)%s*(@+)%s*(.*)$")

    if not open or not close or open ~= close or #open < 2 then
        return nil
    end

    ---@type BigDiffPos[]
    local positions = {}
    for _, part in ipairs(vim.split(inner, "%s+")) do
        local start_line, count = part:match("^[%-+](%d+),?(%d*)$")
        if not start_line then
            return nil
        end
        positions[#positions + 1] = {
            line = tonumber(start_line) or 1,
            count = tonumber(count) or 1,
        }
    end

    -- One position per `@`: `@@` is left/right, `@@@` adds one parent.
    if #positions ~= #open then
        return nil
    end

    local right = table.remove(positions)
    local left = table.remove(positions, 1)

    ---@type BigDiffHunk
    return {
        diff = { line },
        line = right and right.line or 1,
        count = right and right.count or 0,
        change_line = right and right.line or 1,
        change_count = right and right.count or 0,
        left = left or { line = 1, count = 0 },
        right = right or { line = 1, count = 0 },
        parents = #positions > 0 and positions or nil,
        context = context ~= "" and context or nil,
    }
end

---Derives the changed ranges on the right side of a hunk.
---
---With context lines the hunk header no longer points at a change, and one
---hunk can hold several unrelated edits. Splitting the body back into
---contiguous changed ranges keeps per-change granularity (and per-change
---treesitter scopes) while the hunk itself keeps its context for previews.
---@param hunk BigDiffHunk
local function compute_changes(hunk)
    local versions = 2 + (hunk.parents and #hunk.parents or 0)
    local prefix_width = versions - 1
    local right_index = hunk.right.line - 1

    ---@type BigDiffPos[]
    local changes = {}
    local open = nil

    local function close()
        if open then
            changes[#changes + 1] = {
                line = open.first,
                count = open.last - open.first + 1,
            }
            open = nil
        end
    end

    local function mark(line)
        if open then
            open.last = math.max(open.last, line)
        else
            open = { first = line, last = line }
        end
    end

    for index = 2, #hunk.diff do
        local text = hunk.diff[index]

        -- "\ No newline at end of file" belongs to the previous line.
        if text:sub(1, 1) ~= "\\" then
            local prefix = text:sub(1, prefix_width)
            -- A line survives on the right unless every side deleted it.
            local removed_everywhere = prefix ~= ""
                and prefix:gsub("%-", "") == ""
            local changed = prefix:find("[+%-]") ~= nil

            if removed_everywhere then
                mark(right_index + 1)
            else
                right_index = right_index + 1
                if changed then
                    mark(right_index)
                else
                    close()
                end
            end
        end
    end
    close()

    hunk.changes = changes
    hunk.change_line = changes[1] and changes[1].line or hunk.right.line
    if #changes > 0 then
        local last = changes[#changes]
        hunk.change_count = last.line + last.count - hunk.change_line
    else
        hunk.change_count = hunk.right.count
    end
end

---@param block BigDiffBlock
local function finalize_block(block)
    for _, line in ipairs(block.header) do
        if line:find("^%-%-%- ") then
            block.left = normalize_diff_path(line:sub(5))
        elseif line:find("^%+%+%+ ") then
            block.right = normalize_diff_path(line:sub(5))
        elseif line:find("^rename from ") then
            block.rename = block.rename or {}
            block.left =
                normalize_diff_path(line:match("^rename from (.*)"), false)
            block.rename.from = block.left
        elseif line:find("^rename to ") then
            block.rename = block.rename or {}
            block.right =
                normalize_diff_path(line:match("^rename to (.*)"), false)
            block.rename.to = block.right
        elseif line:find("^copy from ") then
            block.copy = block.copy or {}
            block.left =
                normalize_diff_path(line:match("^copy from (.*)"), false)
            block.copy.from = block.left
        elseif line:find("^copy to ") then
            block.copy = block.copy or {}
            block.right =
                normalize_diff_path(line:match("^copy to (.*)"), false)
            block.copy.to = block.right
        elseif line:find("^new file mode ") then
            block.new = line:match("^new file mode (.*)")
        elseif line:find("^deleted file mode ") then
            block.delete = line:match("^deleted file mode (.*)")
        elseif line:find("^old mode ") then
            block.mode = block.mode or {}
            block.mode.from = line:match("^old mode (.*)")
        elseif line:find("^new mode ") then
            block.mode = block.mode or {}
            block.mode.to = line:match("^new mode (.*)")
        elseif line:find("^similarity index ") then
            block.similarity = tonumber(line:match("^similarity index (%d+)%%"))
                or 0
        elseif line:find("^dissimilarity index ") then
            block.dissimilarity = tonumber(
                line:match("^dissimilarity index (%d+)%%")
            ) or 0
        elseif line:find("^index ") then
            local from, to, mode = line:match("^index (%S+)%.%.(%S+)%s*(%d*)$")
            if from then
                block.index =
                    { from = from, to = to, mode = mode ~= "" and mode or nil }
            end
        elseif
            line:find("^Binary files ")
            or line:find("^GIT binary patch")
            or line:find("^Files .* differ$")
        then
            block.binary = true
        end
    end

    local first = block.header[1] or ""
    if not block.right and not block.left and first:find("^diff") then
        -- Without `---`/`+++` lines both sides name the same file.
        if first:find("^diff %-%-cc ") then
            block.left = normalize_diff_path(first:match("^diff %-%-cc (.+)$"))
            block.right = block.left
        else
            first = first:gsub("^diff ", ""):gsub("^%s*%-%S+%s*", "")
            local index = 1
            while index <= #first do
                local space = first:find(" ", index, true)
                if not space then
                    break
                end
                index = space + 1
                local left = normalize_diff_path(first:sub(1, space - 1))
                local right = normalize_diff_path(first:sub(space + 1))
                if left == right then
                    block.left = left
                    block.right = right
                    break
                end
            end
        end
    end

    block.file = block.right or block.left or block.file

    for _, hunk in ipairs(block.hunks) do
        compute_changes(hunk)
    end

    table.sort(block.hunks, function(a, b)
        return a.line < b.line
    end)
end

---@param lines string[]
---@return BigDiffDiff
function M.parse(lines)
    ---@type BigDiffBlock[]
    local blocks = {}
    ---@type string[]
    local header = {}
    ---@type BigDiffBlock?
    local block
    ---@type BigDiffHunk?
    local hunk
    local with_diff_header = false

    local function emit()
        if not block then
            return
        end
        hunk = nil
        finalize_block(block)
        blocks[#blocks + 1] = block
        block = nil
    end

    for _, text in ipairs(lines) do
        local starts_block = text:find("^diff") ~= nil
            or (
                not with_diff_header
                and text:find("^%-%-%- ") ~= nil
                and (not block or hunk ~= nil)
            )

        local skip = not block and text:find("^%s*$") ~= nil

        if skip then -- luacheck: ignore
            -- Ignore blank lines between blocks.
        elseif starts_block then
            with_diff_header = with_diff_header or text:find("^diff") == 1
            emit()
            block = { file = "", header = { text }, hunks = {} }
        elseif block and text:find("@@", 1, true) == 1 then
            hunk = M.parse_hunk_header(text)
            if hunk then
                block.unmerged = block.unmerged or (hunk.parents ~= nil) or nil
                block.hunks[#block.hunks + 1] = hunk
            end
        elseif hunk then
            hunk.diff[#hunk.diff + 1] = text
        elseif block then
            block.header[#block.header + 1] = text
        elseif #blocks == 0 then
            header[#header + 1] = text
        end
    end

    emit()

    return { blocks = blocks, header = header }
end

---@param diff string|string[]|BigDiffDiff
---@return BigDiffDiff
function M.get(diff)
    if type(diff) == "string" then
        diff = vim.split(diff, "\n", { plain = true })
    end
    if type(diff) == "table" and type(diff[1]) == "string" then
        return M.parse(diff)
    end
    ---@cast diff BigDiffDiff
    return diff
end

---Renders a block back to diff text (block header plus the given hunks).
---@param block BigDiffBlock
---@param hunks? BigDiffHunk[] defaults to every hunk of the block
---@return string
function M.to_text(block, hunks)
    local lines = vim.deepcopy(block.header)
    for _, item in ipairs(hunks or block.hunks) do
        vim.list_extend(lines, item.diff)
    end
    return table.concat(lines, "\n")
end

return M
