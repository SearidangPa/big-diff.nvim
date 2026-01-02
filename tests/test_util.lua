local M = {}

---@param content string
---@param ft string
---@param filename string?
---@return integer bufnr, string path
function M.create_test_file(content, ft, filename)
  filename = filename or (os.tmpname() .. "." .. (ft == "python" and "py" or ft))
  local f = io.open(filename, "w")
  if f then
    f:write(content)
    f:close()
  end
  
  -- We need to ensure the buffer is loaded for TreeSitter to work
  local bufnr = vim.fn.bufadd(filename)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].filetype = ft
  
  return bufnr, filename
end

return M
