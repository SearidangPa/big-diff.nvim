## Layout

- `lua/big-diff/nvim/` - big-diff (mini.diff fork), mini.nvim code style
  (2 spaces, single quotes).
- `lua/diffhopper/` - diffhopper split diff, pickers and jumplist, with its own
  style in `lua/diffhopper/.stylua.toml` (4 spaces, double quotes).

## Development Commands

These cover `lua/diffhopper` only:

- **Linting**: Run `make lua_lint` to lint the code using `luacheck`.
- **Formatting**: Run `make lua_fmt` to format code with `stylua`.
- **Check All**: Run `make check` to run both linting and format checking.

Tests: `nvim --headless -u NONE -l tests/differ.lua`.
