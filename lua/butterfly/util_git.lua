local M = {}

---@type table<string, { branch?: string, inflight?: fun(branch: string)[] }>
local default_base_branch_cache = {}

---@param bufnr? integer
---@return string?
function M.find_git_root(bufnr)
    bufnr = bufnr or 0
    local bufname = vim.api.nvim_buf_get_name(bufnr)

    local path
    if bufname == "" then
        path = vim.fn.getcwd()
    else
        -- IMPORTANT: resolve symlinks (stow)
        path = vim.fn.resolve(bufname)
    end

    -- Normalize to absolute dir
    local dir = vim.fn.fnamemodify(path, ":p:h")

    while dir ~= "/" and dir ~= "" do
        local git_path = dir .. "/.git"
        if
            vim.fn.isdirectory(git_path) == 1
            or vim.fn.filereadable(git_path) == 1
        then
            return dir
        end
        dir = vim.fn.fnamemodify(dir, ":h")
    end

    return nil
end

---@param callback fun(branch: string)
---@param opts? { git_root?: string, fallback?: string, no_cache?: boolean }
function M.get_default_base_branch_async(callback, opts)
    opts = opts or {}
    local fallback = opts.fallback or "main"

    local git_root = opts.git_root or M.find_git_root()
    if not git_root then
        callback(fallback)
        return
    end

    local cached = default_base_branch_cache[git_root]
    if not opts.no_cache and cached and cached.branch then
        callback(cached.branch)
        return
    end

    cached = cached or {}
    default_base_branch_cache[git_root] = cached

    -- Coalesce concurrent callers: only run one job per git_root.
    if cached.inflight then
        table.insert(cached.inflight, callback)
        return
    end

    cached.inflight = { callback }

    local function run_callbacks(branch)
        local callbacks = cached.inflight or {}
        cached.inflight = nil
        for _, cb in ipairs(callbacks) do
            vim.schedule(function()
                cb(branch)
            end)
        end
    end

    vim.system({
        "git",
        "-C",
        git_root,
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
    }, { text = true }, function(obj)
        if obj.code ~= 0 then
            run_callbacks(fallback)
            return
        end

        local ref = vim.trim(obj.stdout or "")
        local branch = ref:match("^refs/remotes/origin/(.+)$") or ""
        if branch == "" then
            branch = fallback
        end

        cached.branch = branch

        run_callbacks(branch)
    end)
end

---@param base? string
---@param this_file? string
---@param callback fun(hunks: table[])
function M.get_diff_hunks(base, this_file, callback)
    base = base or "HEAD"

    local cmd = { "git", "diff", base, "--unified=0" }
    if this_file and this_file ~= "" then
        cmd[#cmd + 1] = "--"
        cmd[#cmd + 1] = this_file
    end

    vim.system(cmd, { text = true }, function(obj)
        local hunks = {}
        local output = obj.stdout or ""
        local current_file = nil

        for line in output:gmatch("[^\n]+") do
            local file = line:match("^%+%+%+ b/(.+)$")
            if file then
                current_file = file
            elseif current_file then
                local start_line, count = line:match("^@@ .* %+(%d+),?(%d*)")
                if start_line then
                    count = tonumber(count) or 1
                    table.insert(hunks, {
                        file = current_file,
                        line = tonumber(start_line),
                        count = count,
                    })
                end
            end
        end

        vim.schedule(function()
            callback(hunks)
        end)
    end)
end

return M
