local cwd = vim.fn.getcwd()
vim.opt.runtimepath:append(cwd)
vim.opt.runtimepath:append(cwd .. "/../beaver.nvim")

local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:append(plenary_path)

-- Sibling plugin paths
vim.opt.runtimepath:append(cwd .. "/../plenary.nvim")
vim.opt.runtimepath:append(cwd .. "/../nvim-treesitter")

require("plenary.busted")

vim.cmd("runtime plugin/plenary.vim")
