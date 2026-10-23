# diffhopper keeps its own style (4 spaces, double quotes); the big-diff
# modules follow mini.nvim's style, so these targets cover lua/diffhopper only.
DIFFHOPPER_LUA := lua/diffhopper
STYLUA_CONFIG := lua/diffhopper/.stylua.toml

lua_fmt:
	echo "===> Formatting"
	stylua $(DIFFHOPPER_LUA) --config-path=$(STYLUA_CONFIG)

lua_fmt_check:
	echo "===> Checking format"
	stylua $(DIFFHOPPER_LUA) --config-path=$(STYLUA_CONFIG) --check

lua_lint:
	echo "===> Linting"
	luacheck $(DIFFHOPPER_LUA) --globals vim

check: lua_lint lua_fmt_check
