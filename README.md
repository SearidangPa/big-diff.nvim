# butterfly.nvim

`butterfly.nvim` is a small set of Neovim tools for moving through code and reviewing changes:

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
  "searidangpa/butterfly.nvim",
  dependencies = {
    "folke/snacks.nvim",
    "echasnovski/mini.nvim",
  },
  config = function()
    require("butterfly").setup()
  end,
}
```

## What `setup()` does

Calling `require("butterfly").setup()`:

- loads picker modules
- defines plugin highlight groups
- updates highlights when your colorscheme changes

## Commands

### `:ButterflyDiff`

Toggle split diff mode.

- if split diff is already open, it closes
- if split diff is closed, it opens a branch picker and compares against the selected branch

### `:ButterflyDiff <base-ref>`

Open split diff directly against a base ref, for example:

- `:ButterflyDiff HEAD`
- `:ButterflyDiff main`
- `:ButterflyDiff origin/main`

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
local butterfly = require("butterfly")

butterfly.setup()
butterfly.split_diff_main() -- compare against detected default base branch
butterfly.split_diff()      -- compare against HEAD
```

### Jumplist picker

```lua
local jumplist = require("butterfly.jumplist_fzf")

jumplist.pick_cwd()    -- jumps from current working directory scope
jumplist.pick_buffer() -- jumps in current buffer only
```

### Git diff picker

```lua
local diff = require("butterfly.git_diff_fzf")

diff.pick_vs_default_branch()
diff.pick_file_vs_default_branch()
diff.pick_tests_vs_default_branch()
diff.pick_context_vs_default_branch()

diff.pick_vs_head()
diff.pick_file_vs_head()
```

## Suggested keymaps

```lua
local butterfly = require("butterfly")
local jumplist = require("butterfly.jumplist_fzf")
local diff = require("butterfly.git_diff_fzf")

vim.keymap.set("n", "<leader>bd", "<cmd>ButterflyDiff<cr>", { desc = "Butterfly split diff" })
vim.keymap.set("n", "<leader>bj", jumplist.pick_cwd, { desc = "Butterfly jumplist (cwd)" })
vim.keymap.set("n", "<leader>bJ", jumplist.pick_buffer, { desc = "Butterfly jumplist (buffer)" })
vim.keymap.set("n", "<leader>bg", diff.pick_vs_default_branch, { desc = "Butterfly git diff" })
vim.keymap.set("n", "<leader>bf", diff.pick_file_vs_default_branch, { desc = "Butterfly file diff" })
```

## Notes

- split diff works only inside a git repository
- default base branch detection prefers `origin/HEAD`, then upstream branch, then falls back to `main`
- if overlays or highlights look wrong, confirm `mini.diff` and `big-diff` are installed and loaded
