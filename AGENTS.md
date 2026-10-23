## Layout

- `lua/big-diff/nvim/` - inline diffs (a mini.diff fork), `:Diff`/`:Differ`,
  the split view (`split/`), the git hunk picker (`picker/`) and the jumplist
  picker. Code follows mini.nvim's style: 2 spaces, single quotes.

## Development Commands

- **Tests**: Run `make test` (`nvim --headless -u NONE -l tests/differ.lua`).
