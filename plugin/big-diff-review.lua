if vim.g.loaded_big_diff_review_entrypoint then return end
vim.g.loaded_big_diff_review_entrypoint = true

vim.api.nvim_create_user_command('BigDiffReviewStart', function()
  local core = require('big-diff.nvim')
  if not (_G.MiniDiff and type(_G.MiniDiff.config) == 'table') then
    core.setup()
  else
    core = _G.MiniDiff
  end
  local review = core.review
  if not review then
    review = require('big-diff.nvim.review')
    core.review = review
    review.setup((core.config and core.config.review) or {})
  end
  review.start({ handoff_path = vim.env.BIG_DIFF_REVIEW_HANDOFF })
end, { desc = 'Start a Pi-launched big-diff code review' })
