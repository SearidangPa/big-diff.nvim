vim.opt.rtp:prepend('.')
vim.opt.rtp:prepend('../plenary.nvim/')

-- Mock Snacks (external dependency)
_G.Snacks = {
  picker = setmetatable({
    highlight = {
      format = function() end,
      highlight = function() end,
    }
  }, {
    __call = function(_, opts) return {} end
  })
}

-- Mock config.util_git
package.preload['config.util_git'] = function()
  return {
    get_default_base_branch_async = function(cb)
      if cb then cb('main') end
    end
  }
end

vim.cmd('runtime! plugin/plenary.vim')
