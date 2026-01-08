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

    vim.system({
        "git",
        "-C",
        git_root,
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
    }, { text = true }, function(obj)
        if obj.code ~= 0 then
            local callbacks = cached.inflight or {}
            cached.inflight = nil
            for _, cb in ipairs(callbacks) do
                cb(fallback)
            end
            return
        end

        local ref = vim.trim(obj.stdout or "")
        local branch = ref:match("^refs/remotes/origin/(.+)$") or ""
        if branch == "" then
            branch = fallback
        end

        cached.branch = branch

        local callbacks = cached.inflight or {}
        cached.inflight = nil
        for _, cb in ipairs(callbacks) do
            cb(branch)
        end
    end)
end

return M
