local M = {}

local languages = {
  lua = 'lua', ts = 'typescript', tsx = 'tsx', js = 'javascript', jsx = 'jsx',
  py = 'python', rb = 'ruby', rs = 'rust', go = 'go', c = 'c', h = 'c',
  cpp = 'cpp', cc = 'cpp', java = 'java', sh = 'sh', zsh = 'zsh', md = 'markdown',
  json = 'json', yaml = 'yaml', yml = 'yaml', vim = 'vim',
}

local function fence_for(text)
  local longest = 0
  for run in text:gmatch('`+') do longest = math.max(longest, #run) end
  return string.rep('`', math.max(3, longest + 1))
end

local function quote(text)
  local result = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do result[#result + 1] = '> ' .. line end
  return table.concat(result, '\n')
end

M.markdown = function(session, reviews)
  reviews = vim.deepcopy(reviews)
  table.sort(reviews, function(a, b)
    if a.file_path ~= b.file_path then return a.file_path < b.file_path end
    local a_line = a.side == 'old' and (a.ref_line_start or 0) or (a.line_start or 0)
    local b_line = b.side == 'old' and (b.ref_line_start or 0) or (b.line_start or 0)
    if a_line ~= b_line then return a_line < b_line end
    return a.id < b.id
  end)

  local target = session.target_description or 'working tree compared with Git index'
  local output = {
    '# Code Review Feedback', '',
    'Repository: `' .. session.repo_root:gsub('`', '\\`') .. '`',
    'Review target: ' .. target,
    'Submission: `' .. session.request.requestId .. '`',
    '<!-- big-diff-request-id:' .. session.request.requestId .. ' -->', '',
    'Treat these as human review findings. Inspect each finding against the current code. Address confirmed issues and explain any finding you reject. Do not independently review unrelated parts of the diff.',
  }

  for index, review in ipairs(reviews) do
    local first = review.side == 'old' and review.ref_line_start or review.line_start
    local last = review.side == 'old' and review.ref_line_end or review.line_end
    local range = first == last and ('line ' .. first) or string.format('lines %d-%d', first, last)
    output[#output + 1] = ''
    output[#output + 1] = string.format('## %d. `%s` %s (%s side)', index, review.file_path:gsub('`', '\\`'), range, review.side)
    output[#output + 1] = ''
    local extension = review.file_path:match('%.([^./]+)$') or ''
    local fence = fence_for(review.selected_text or '')
    output[#output + 1] = fence .. (languages[extension] or '')
    output[#output + 1] = review.selected_text or ''
    output[#output + 1] = fence
    output[#output + 1] = ''
    output[#output + 1] = quote(review.comment or '')
  end
  output[#output + 1] = ''
  return table.concat(output, '\n')
end

return M
