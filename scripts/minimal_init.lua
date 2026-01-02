vim.opt.rtp:prepend('.')
vim.opt.rtp:prepend('../plenary.nvim/')

-- Mock Snacks (external dependency)
_G.Snacks = {
  picker = setmetatable({
    last_opts = nil, -- Store arguments for assertions
    highlight = {
      format = function() end,
      highlight = function() end,
    }
  }, {
    __call = function(self, opts)
      self.last_opts = opts
      return {}
    end
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
