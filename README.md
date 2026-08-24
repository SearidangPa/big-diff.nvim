# diffhopper.nvim

`diffhopper.nvim` is a small set of Neovim tools for moving through code and reviewing changes:

- jumplist navigation with a picker UI
- git hunk browsing with a picker UI
- side-by-side split diff browsing for changed files

## Requirements

- `folke/snacks.nvim` - used for picker UIs (`Snacks.picker`)
- `echasnovski/mini.nvim` - uses `mini.diff` highlight groups and base-ref refresh flow
- `big-diff` - used by split diff mode to toggle/enable overlays

## Installation

Example with `lazy.nvim`:

```lua
{
  "searidangpa/diffhopper.nvim",
  dependencies = {
    "folke/snacks.nvim",
    "echasnovski/mini.nvim",
  },
  config = function()
    require("diffhopper").setup()
  end,
}
```

## What `setup()` does

Calling `require("diffhopper").setup(opts)`:

- stores configuration (see below)
- loads picker modules
- defines plugin highlight groups
- updates highlights when your colorscheme changes

### Configuration

```lua
require("diffhopper").setup({
  git = {
    context_lines = 3,      -- unified context captured for hunk previews
    merge_base = true,      -- diff against the merge base, not the ref tip
    include_untracked = true,
    ignore_whitespace = false,
    untracked_max_bytes = 512 * 1024,
  },
  preview = {
    style = "fancy",        -- "fancy" | "syntax" | "terminal"
    cmd = { "delta" },      -- used by the "terminal" style
    max_hunk_lines = 200,   -- render only the last N lines of a huge hunk
    hunk_header = true,     -- or "context" to hide the @@ line and keep its context
  },
  picker = {
    group = false,          -- true: one item per file instead of one per hunk
    jump_labels = true,     -- show <M-a>..<M-z> labels on picker items
  },
})
```

Preview styles:

- `fancy` - diffhopper's own renderer: file header with badges, dual old/new
  line-number gutter, per-line add/delete/context/conflict highlights
- `syntax` - the raw patch with `ft=diff`
- `terminal` - pipes the patch through an external pager such as `delta`
  (`--dark`/`--light` is added automatically); falls back to `fancy` when the
  command is not installed

## Commands

### `:DiffHopper`

Toggle split diff mode.

- if split diff is already open, it closes
- if split diff is closed, it opens a branch picker and compares against the selected branch

### `:DiffHopper <base-ref>`

Open split diff directly against a base ref, for example:

- `:DiffHopper HEAD`
- `:DiffHopper main`
- `:DiffHopper origin/main`

The ref is passed to git diff logic, so any valid git revision/reference works.

## Split diff behavior

When split diff opens:

- left window shows changed files grouped by directory
- main window opens the selected file
- pressing `<CR>` in the left file list opens that file in the main window
- untracked files are included
- deleted files are shown in a scratch buffer with historical content from the base ref

If no changes are found for the chosen base ref, the plugin notifies and exits split diff mode.

## Lua API

### Top-level module

```lua
local diffhopper = require("diffhopper")

diffhopper.setup()
diffhopper.split_diff_main() -- compare against detected default base branch
diffhopper.split_diff()      -- compare against HEAD
```

### Jumplist picker

```lua
local jumplist = require("diffhopper.jumplist_fzf")

jumplist.pick_cwd()    -- jumps from current working directory scope
jumplist.pick_buffer() -- jumps in current buffer only
```

### Git diff picker

```lua
local diff = require("diffhopper.git_diff_fzf")

diff.pick_vs_default_branch()
diff.pick_file_vs_default_branch()
diff.pick_tests_vs_default_branch()
diff.pick_context_vs_default_branch()

diff.pick_vs_head()
diff.pick_file_vs_head()

diff.pick_staged()   -- only what is in the index (git diff --cached)
diff.pick_unstaged() -- only what is not staged yet (git diff)

-- every picker accepts the same option table
diff.pick({
  base = "origin/main",
  group = true,             -- one row per file
  ignore_whitespace = true, -- --ignore-all-space
  staged = true,            -- true: index, false: worktree, nil: both
  annotations = {           -- drawn onto the rendered diff (PR review comments)
    {
      file = "pkg/a.go",
      side = "right",
      line = 42,
      text = { { { "reviewer: ", "Comment" }, { "why the extra call?" } } },
    },
  },
})
```

### Git diff picker keys

When `picker.jump_labels` is enabled, the picker also supports `<M-a>`..`<M-z>`
for direct item jumps:

| key     | action                                            |
| ------- | ------------------------------------------------- |
| `<M-S>` | cycle staged -> unstaged -> both                  |
| `<M-W>` | toggle `--ignore-all-space`                       |
| `<M-G>` | toggle grouping (one row per file)                |

Each item carries the patch it represents in `item.diff` and the parsed file
metadata in `item.block` (rename/copy, new/deleted mode, mode change, binary,
unmerged, `index` blob range), so custom actions can use them.

## Suggested keymaps

```lua
local diffhopper = require("diffhopper")
local jumplist = require("diffhopper.jumplist_fzf")
local diff = require("diffhopper.git_diff_fzf")

vim.keymap.set("n", "<leader>bd", "<cmd>DiffHopper<cr>", { desc = "DiffHopper split diff" })
vim.keymap.set("n", "<leader>bj", jumplist.pick_cwd, { desc = "DiffHopper jumplist (cwd)" })
vim.keymap.set("n", "<leader>bJ", jumplist.pick_buffer, { desc = "DiffHopper jumplist (buffer)" })
vim.keymap.set("n", "<leader>bg", diff.pick_vs_default_branch, { desc = "DiffHopper git diff" })
vim.keymap.set("n", "<leader>bf", diff.pick_file_vs_default_branch, { desc = "DiffHopper file diff" })
```

## What the git diff picker shows

- one row per contiguous change, named after its treesitter scope (`func X`),
  falling back to git's own `@@ ... @@ func()` trailer, then the first line
- import-only churn is filtered out
- untracked files appear as new-file hunks
- deleted, binary, mode-only and rename-only changes appear as a single row
  with a badge instead of silently disappearing
- unmerged paths are parsed as combined (`diff --cc`) diffs, conflict markers
  included

## Notes

- split diff works only inside a git repository
- default base branch detection prefers `origin/HEAD`, then upstream branch, then falls back to `main`
- if overlays or highlights look wrong, confirm `mini.diff` and `big-diff` are installed and loaded
