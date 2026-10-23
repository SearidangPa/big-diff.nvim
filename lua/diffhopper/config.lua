local M = {}

---@class DiffHopperGitConfig
---@field context_lines number lines of context captured for hunk previews
---@field merge_base boolean diff against the merge base of the given ref
---@field include_untracked boolean list untracked files as new-file hunks
---@field ignore_whitespace boolean pass --ignore-all-space
---@field untracked_max_bytes number untracked files bigger than this are shown as a stub

---@class DiffHopperPreviewConfig
---@field style "fancy"|"syntax"|"terminal"
---@field cmd string[] command used by the "terminal" style
---@field max_hunk_lines? number only render the last N lines of a hunk
---@field hunk_header boolean|"context" render the hunk header row, or only its context

---@class DiffHopperPickerConfig
---@field group boolean collapse every hunk of a file into a single item
---@field jump_labels boolean show one-key jump labels on picker items

---@class DiffHopperConfig
---@field git DiffHopperGitConfig
---@field preview DiffHopperPreviewConfig
---@field picker DiffHopperPickerConfig

---@type DiffHopperConfig
M.defaults = {
    git = {
        context_lines = 3,
        merge_base = true,
        include_untracked = true,
        ignore_whitespace = false,
        untracked_max_bytes = 512 * 1024,
    },
    preview = {
        style = "fancy",
        cmd = { "delta" },
        max_hunk_lines = 200,
        hunk_header = true,
    },
    picker = {
        group = false,
        jump_labels = true,
    },
}

---@type DiffHopperConfig
M.options = vim.deepcopy(M.defaults)

---@param options? table
function M.setup(options)
    M.options = vim.tbl_deep_extend("force", M.options, options or {})
    return M.options
end

---@return DiffHopperConfig
function M.get()
    return M.options
end

return M
