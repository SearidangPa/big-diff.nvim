local cwd = vim.fn.getcwd()
vim.opt.runtimepath:append(cwd)

local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:append(plenary_path)

require("plenary.busted")

vim.cmd("runtime plugin/plenary.vim")
