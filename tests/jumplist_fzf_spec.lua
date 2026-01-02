local assert = require("luassert")
local stub = require("luassert.stub")
local test_util = require("tests.test_util")
local jumplist_fzf = require("butterfly.jumplist_fzf")

describe("jumplist_fzf", function()
  local snapshot
  
  before_each(function()
    snapshot = assert:snapshot()
    _G.Snacks.picker.last_opts = nil
  end)

  after_each(function()
    snapshot:revert()
  end)

  it("filters jumplist and resolves scopes", function()
    local content = "function MyFunc() end"
    local bufnr, filepath = test_util.create_test_file(content, "lua")
    
    -- Mock getjumplist
    -- Returns: { list of jumps, current_index }
    -- Jump item: { bufnr = X, lnum = Y, col = Z, ... }
    local jumps = {
      { bufnr = bufnr, lnum = 1, col = 0 }
    }
    
    -- We can override vim.fn.getjumplist by simple assignment or stub
    -- Since vim.fn is a metatable, stub works if we stub the index? 
    -- Actually in Neovim Lua vim.fn is a bit special. 
    -- But usually simple replacement works for tests running in nvim.
    vim.fn.getjumplist = function() return { jumps, 1 } end
    
    -- We assume the buffer is already loaded/named correctly by create_test_file
    -- But jumplist_fzf.lua calls vim.fn.bufname(bufnr)
    -- Since we used bufadd(filepath), bufname(bufnr) should return filepath (relative or absolute)
    -- verify:
    assert.are.equal(filepath, vim.fn.bufname(bufnr))
    
    -- Mock getcwd to be the directory of our temp file so is_under_cwd passes
    local dir = vim.fn.fnamemodify(filepath, ":h")
    local original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function() return dir end

    jumplist_fzf.pick()
    
    -- Restore getcwd
    vim.fn.getcwd = original_getcwd

    local opts = _G.Snacks.picker.last_opts
    assert.is_not_nil(opts, "Snacks.picker should be called")
    
    local items = opts.items
    local found = false
    for _, item in ipairs(items) do
      if item.file == filepath and item.line == 1 then
        found = true
        assert.is_not_nil(item.scope)
        assert.matches("MyFunc", item.scope.name)
      end
    end
    assert.is_true(found, "Should find jumplist item")
    
    os.remove(filepath)
  end)
end)
