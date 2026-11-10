.PHONY: test

test:
	nvim --headless -u NONE -l tests/differ.lua
	nvim --headless -u NONE -l tests/tree.lua
