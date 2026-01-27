## Development Commands

- **Testing**: Run all tests with `make test`. This uses `plenary.nvim`'s busted implementation.
  - To run a single test file, you may need to use `plenary`'s test runner directly or filter the `make test` command if supported, but typically `make test` runs the suite.
  - Test configuration uses `scripts/minimal_init.lua`.
- **Linting**: Run `make lua_lint` to lint the code using `luacheck`.
- **Formatting**: Run `make lua_fmt` to format code with `stylua`.
- **Check All**: Run `make check` to run both linting and format checking.

## Architecture

This is a Neovim plugin written in Lua. It provides utilities for jumplist navigation and git diff viewing, integrating with FZF and `mini.diff`.

### Key Components

- **Entry Point**: `lua/butterfly/init.lua` - Sets up user commands (`ButterflyDiff`) and highlights.
- **Split Diff Viewer**: Located in `lua/butterfly/split_diff/`.
  - Provides a side-by-side file navigation UI for git diffs.
  - Integrates with `mini.diff` to show diff overlays.
  - `init.lua`: Main logic for opening the diff view and managing state.
  - `ui.lua`: Handles rendering the file list and setting up keymaps.
  - `git.lua`: Git operations (fetching changed files).
- **FZF Integrations**:
  - `lua/butterfly/jumplist_fzf.lua`: Enhanced jumplist navigation.
  - `lua/butterfly/git_diff_fzf.lua`: FZF source for git diffs.
- **Utilities**:
  - `lua/butterfly/util_git.lua`: Helper functions for git commands.
  - `lua/butterfly/utils_picker_context.lua`: Context helpers for pickers.

### Dependencies

- **Runtime**: `mini.diff` (part of `mini.nvim`) is required for the split diff feature.
- **Dev/Test**: `plenary.nvim` is required for running tests. `luacheck` and `stylua` are used for linting and formatting.
