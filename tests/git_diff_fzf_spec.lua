local assert = require("luassert")
local test_util = require("tests.test_util")
local git_diff_fzf = require("butterfly.git_diff_fzf")

describe("git_diff_fzf", function()
  local original_system = vim.system

  after_each(function()
    vim.system = original_system
    _G.Snacks.picker.last_opts = nil
  end)

  it("parses git diff and resolves scopes", function()
    -- Create a dummy file
    local content = [[
local M = {}

function M.test_func()
  print("hello")
end

return M
]]
    local bufnr, filepath = test_util.create_test_file(content, "lua")

    -- Mock git diff output
    -- The parser expects: '+++ b/<filepath>'
    local diff_output = string.format("+++ b/%s\n@@ -0,0 +4,1 @@\n", filepath)

    vim.system = function(cmd, opts, cb)
      -- Verify command args if needed
      cb({ stdout = diff_output, code = 0 })
    end

    -- Run pick
    git_diff_fzf.pick()

    -- Wait for vim.schedule to execute the callback
    vim.wait(100, function()
      return _G.Snacks.picker.last_opts ~= nil
    end)

    local opts = _G.Snacks.picker.last_opts
    assert.is_not_nil(opts, "Snacks.picker should be called")

    local items = opts.items
    assert.is_not_nil(items)
    assert.is_true(#items >= 1, "Should have items")

    local child_item = nil
    for _, item in ipairs(items) do
      if item.line == 4 and item.file == filepath and not item.is_header then
        child_item = item
        break
      end
    end

    assert.is_not_nil(child_item, "Should find the item at line 4")

    -- Assert scope is not nil before checking name
    if child_item.scope == nil then
      -- Fallback to verify context line if scope is missing, or fail
      assert.is_true(false, "Scope was not detected for " .. filepath .. ":4")
    end
    assert.matches("test_func", child_item.scope.name)

    os.remove(filepath)
  end)
end)
