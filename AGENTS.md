## Development Commands

- **Testing**: Run all tests with `make test`. This uses `plenary.nvim`'s busted implementation.
  - To run a single test file, you may need to use `plenary`'s test runner directly or filter the `make test` command if supported, but typically `make test` runs the suite.
  - Test configuration uses `scripts/minimal_init.lua`.
- **Linting**: Run `make lua_lint` to lint the code using `luacheck`.
- **Formatting**: Run `make lua_fmt` to format code with `stylua`.
- **Check All**: Run `make check` to run both linting and format checking.

