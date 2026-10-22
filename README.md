# big-diff.nvim

Inline Git diffs for Neovim, with a file-tree viewer provided by
[diffhopper.nvim](https://github.com/searidangpa/diffhopper.nvim).

## Pull request diffs

Check out the PR in its local repository, then open a file in Neovim and run:

```vim
:Differ https://github.com/PreVeil/drive/pull/1944
```

This PR targets `release/6.3.3`, not `main`. `:Differ` reads the actual base
and head commits using `gh`, fetches the base commit if missing, and opens the
existing split/file-tree view against their **merge-base**, matching GitHub's
three-dot comparison.

Requirements:

- Git, an authenticated GitHub CLI (`gh auth login`), and `diffhopper.nvim`.
- Local `HEAD` must match the PR head. If it does not, the command tells you to
  run `gh pr checkout <url>`; it never checks out, resets, or overwrites files.
- If the base commit is missing, a remote for the PR's base repository is needed.
  HTTPS and GitHub SSH remotes are supported, including an `upstream` remote for
  fork PRs. Fetching does not move local branches or remote-tracking refs.
- Enough Git history to find the merge-base; deepen shallow clones if needed.

This is a **working-tree view**: local edits and untracked files are included.
The file tree also retains diffhopper's current-directory filtering. Use a clean
checkout and the repository root to see the entire PR without local changes.

Configure the Git source to follow the viewer's selected base (also needed by
`:Diff` and `:DiffHopper`):

```lua
local diff = require('big-diff.nvim')
diff.setup({
  source = diff.gen_source.git({
    ref = function() return vim.g.minidiff_git_base_ref or 'HEAD' end,
  }),
})
```

The commands become available after `setup()`; lazy-loading configurations can
use `Differ` as a command trigger.

## Async Lua callers

`require('big-diff.nvim.differ').open(url)` uses the same path as `:Differ`
and returns an ownership handle: `is_current()`, `has_view()`, and
`cancel(close_view)`. This lets cache/background lookups replace or dismiss
only their own preview. Closing the view or opening another diff invalidates
the handle, using diffhopper's `get_session_id()` generation token.

## Other diff commands

- `:Diff commit` — compare the working tree against `HEAD~1`.
- `:Diff N` — compare the working tree against `HEAD~N`.
- `:FoldBetweenHunk [context]` — fold unchanged regions.

## Tests

```sh
nvim --headless -u NONE -l tests/differ.lua
```

To also exercise the real file tree, overlay, and view cleanup:

```sh
DIFFHOPPER_RTP=/absolute/path/to/diffhopper.nvim nvim --headless -u NONE -l tests/differ.lua
```

Also set `NVIM_CONFIG_RTP=/absolute/path/to/nvim` to exercise the personal
`<leader>dp` cache/GitHub race against the real viewer.
