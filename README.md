# big-diff.nvim

Inline Git diffs for Neovim, plus:

- a split view: changed files in a tree beside the main window, with inline
  overlays against a chosen base
- a git hunk picker with rendered previews
- a jumplist picker

Pickers use [snacks.nvim](https://github.com/folke/snacks.nvim) (`Snacks.picker`).

## Setup

```lua
local diff = require('big-diff.nvim')
diff.setup({
  -- Follow the split view's selected base (needed by `:Diff` and `:Differ`)
  source = diff.gen_source.git({
    ref = function() return vim.g.minidiff_git_base_ref or 'HEAD' end,
  }),

  -- Git hunk picker, defaults shown
  picker = {
    group = false,       -- true: one item per file instead of one per hunk
    jump_labels = true,  -- <M-a>..<M-z> labels on picker items
    git = {
      context_lines = 3, -- unified context captured for hunk previews
      merge_base = true, -- diff against the merge base, not the ref tip
      include_untracked = true,
      ignore_whitespace = false,
      untracked_max_bytes = 512 * 1024,
    },
    preview = {
      style = 'fancy',      -- 'fancy' | 'syntax' | 'terminal'
      cmd = { 'delta' },    -- pager for the 'terminal' style
      max_hunk_lines = 200, -- render only the last N lines of a huge hunk
      hunk_header = true,   -- or 'context' to hide the @@ line but keep its context
    },
  },
})
```

Commands become available after `setup()`; lazy-loading configurations can use
`Diff` and `Differ` as command triggers.

Preview styles:

- `fancy` - file header with badges, dual old/new line-number gutter, per-line
  add/delete/context/conflict highlights
- `syntax` - the raw patch with `ft=diff`
- `terminal` - the patch piped through a pager such as `delta` (`--dark`/`--light`
  is added automatically); falls back to `fancy` when the command is missing

## Commands

- `:Diff` - toggle the split view; when closed, pick a branch to compare against.
- `:Diff <ref>` - open the split view against any Git revision (`main`,
  `origin/main`, a SHA).
- `:Diff N` - against `HEAD~N`; `:Diff commit` is `HEAD~1`.
- `:Differ <pr-url>` - against a GitHub PR's actual base (below).
- `:FoldBetweenHunk [context]` - fold unchanged regions.

## Split view

- the left window lists changed files grouped by directory; `<CR>` opens one in
  the main window
- untracked files are included
- deleted files open in a scratch buffer with their content from the base ref
- if nothing changed against the base, it notifies and closes

```lua
local split = require('big-diff.nvim.split')

split.toggle('HEAD')        -- or split.toggle() to pick a branch
split.toggle_main()         -- detected default base branch
split.toggle_last_commit()  -- HEAD~1
split.open(base)
split.close()
split.next_file()
split.previous_file()
split.toggle_file_tree()
split.toggle_exclude_tests()
```

An open view toggles in three steps: hide the file tree, show it again, close.
The default base branch is `origin/HEAD`, then the upstream branch, then `main`.

## Pull request diffs

Check out the PR in its local repository, then open a file in Neovim and run:

```vim
:Differ https://github.com/PreVeil/drive/pull/1944
```

This PR targets `release/6.3.3`, not `main`. `:Differ` reads the actual base
and head commits using `gh`, fetches the base commit if missing, and opens the
split view against their **merge-base**, matching GitHub's three-dot
comparison.

Requirements:

- Git and an authenticated GitHub CLI (`gh auth login`).
- Local `HEAD` must match the PR head. If it does not, the command tells you to
  run `gh pr checkout <url>`; it never checks out, resets, or overwrites files.
- If the base commit is missing, a remote for the PR's base repository is needed.
  HTTPS and GitHub SSH remotes are supported, including an `upstream` remote for
  fork PRs. Fetching does not move local branches or remote-tracking refs.
- Enough Git history to find the merge-base; deepen shallow clones if needed.

This is a **working-tree view**: local edits and untracked files are included.
The file tree also keeps its current-directory filtering. Use a clean checkout
and the repository root to see the entire PR without local changes.

`require('big-diff.nvim.differ').open(url)` uses the same path as `:Differ`
and returns an ownership handle: `is_current()`, `has_view()`, and
`cancel(close_view)`. This lets cache/background lookups replace or dismiss
only their own preview. Closing the view or opening another diff invalidates
the handle, using the split view's `get_session_id()` generation token.

## Git hunk picker

```lua
local picker = require('big-diff.nvim.picker')

picker.pick_vs_default_branch()
picker.pick_file_vs_default_branch()
picker.pick_tests_vs_default_branch()
picker.pick_context_vs_default_branch()
picker.pick_vs_head()
picker.pick_file_vs_head()
picker.pick_staged()   -- only the index (git diff --cached)
picker.pick_unstaged() -- only what is not staged yet (git diff)

-- every picker accepts the same option table
picker.pick({
  base = 'origin/main',
  group = true,             -- one row per file
  ignore_whitespace = true, -- --ignore-all-space
  staged = true,            -- true: index, false: worktree, nil: both
  annotations = {           -- drawn onto the rendered diff (PR review comments)
    {
      file = 'pkg/a.go',
      side = 'right',
      line = 42,
      text = { { { 'reviewer: ', 'Comment' }, { 'why the extra call?' } } },
    },
  },
})
```

| key     | action                           |
| ------- | -------------------------------- |
| `<M-S>` | cycle staged -> unstaged -> both |
| `<M-W>` | toggle `--ignore-all-space`      |
| `<M-G>` | toggle grouping (one row per file) |

With `jump_labels`, `<M-a>`..`<M-z>` jump straight to an item.

What it shows:

- one row per contiguous change, named after its treesitter scope (`func X`),
  falling back to git's own `@@ ... @@ func()` trailer, then the first line
- import-only churn is filtered out
- untracked files appear as new-file hunks
- deleted, binary, mode-only and rename-only changes appear as a single row
  with a badge
- unmerged paths are parsed as combined (`diff --cc`) diffs, conflict markers
  included

Each item carries its patch in `item.diff` and the parsed file metadata in
`item.block` (rename/copy, new/deleted mode, mode change, binary, unmerged,
`index` blob range), so custom actions can use them.

## Jumplist picker

```lua
local jumplist = require('big-diff.nvim.jumplist')

jumplist.pick_cwd()    -- jumps in the current working directory
jumplist.pick_buffer() -- jumps in the current buffer
```

## Tests

```sh
nvim --headless -u NONE -l tests/differ.lua
```

This covers the real split view, overlay, and view cleanup. Set
`NVIM_CONFIG_RTP=/absolute/path/to/nvim` to also exercise the personal
`<leader>dp` cache/GitHub race against the real view.
