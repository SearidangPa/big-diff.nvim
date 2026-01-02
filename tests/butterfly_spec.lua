local assert = require("luassert")

describe("butterfly", function()
  it("can be required", function()
    local butterfly = require("butterfly")
    assert.is_not_nil(butterfly)
    assert.is_function(butterfly.setup)
  end)

  it("modules can be loaded", function()
    require("butterfly.git_diff_fzf")
    require("butterfly.jumplist_fzf")
  end)
end)
