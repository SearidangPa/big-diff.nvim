local M = {}
local uv = vim.uv or vim.loop

local function now() return math.floor(uv.hrtime() / 1000000) + (M.epoch_offset or 0) end

local function uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return (template:gsub('[xy]', function(c)
    local value = math.random(0, 15)
    if c == 'y' then value = (value % 4) + 8 end
    return string.format('%x', value)
  end))
end

M.initialize_clock = function()
  M.epoch_offset = os.time() * 1000 - math.floor(uv.hrtime() / 1000000)
  math.randomseed(os.time() + vim.fn.getpid())
end

M.new = function(fields)
  local timestamp = now()
  local review = vim.tbl_deep_extend('force', {
    schema_version = 1,
    id = 'review-' .. uuid(),
    revision = 1,
    scope = 'line',
    side = 'new',
    context_before = {},
    context_after = {},
    created_at = timestamp,
    updated_at = timestamp,
    status = 'pending',
  }, fields or {})
  return review
end

M.update_comment = function(review, comment)
  if review.comment == comment then return review end
  review.comment = comment
  review.revision = (review.revision or 0) + 1
  review.updated_at = now()
  review.status = 'pending'
  review.last_submission_id = nil
  return review
end

M.now = now
M.initialize_clock()
return M
