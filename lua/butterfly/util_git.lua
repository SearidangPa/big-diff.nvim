local M = {}

---@type table<string, { branch?: string, inflight?: fun(branch: string)[] }>
local default_base_branch_cache = {}

---@param path string
---@return string
local function normalize_path(path)
    return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
end

---@param path string
---@return boolean
local function is_absolute_path(path)
    if not path or path == "" then
        return false
    end

    return path:sub(1, 1) == "/"
        or path:match("^%a:[/\\]") ~= nil
        or path:match("^\\\\") ~= nil
end

---@param path string
---@return string?
local function find_git_root_from_path(path)
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

    return find_git_root_from_path(path)
end

---@param path string
---@return string?
function M.find_git_root_for_path(path)
    if not path or path == "" then
        return nil
    end

    return find_git_root_from_path(vim.fn.resolve(path))
end

---@param filepath string
---@param git_root string
---@return string
function M.to_repo_relative_path(filepath, git_root)
    local normalized_root = normalize_path(git_root)
    local normalized_file = normalize_path(filepath)
    local root_prefix = normalized_root .. "/"

    if normalized_file == normalized_root then
        return "."
    end

    if normalized_file:sub(1, #root_prefix) == root_prefix then
        return normalized_file:sub(#root_prefix + 1)
    end

    return vim.fs.normalize(filepath)
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

    local function finish(branch)
        cached.branch = branch
        run_callbacks(branch)
    end

    local function resolve_origin_head(callback_fn)
        vim.system({
            "git",
            "-C",
            git_root,
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
        }, { text = true }, function(obj)
            if obj.code ~= 0 then
                callback_fn(nil)
                return
            end

            local ref = vim.trim(obj.stdout or "")
            local branch = ref:match("^refs/remotes/origin/(.+)$") or ""
            if branch == "" then
                callback_fn(nil)
                return
            end

            callback_fn("origin/" .. branch)
        end)
    end

    local function fallback_to_upstream_or_current_branch()
        vim.system({
            "git",
            "-C",
            git_root,
            "rev-parse",
            "--abbrev-ref",
            "--symbolic-full-name",
            "@{upstream}",
        }, { text = true }, function(obj)
            if obj.code == 0 then
                local upstream = vim.trim(obj.stdout or "")
                if upstream ~= "" then
                    finish(upstream)
                    return
                end
            end

            vim.system({
                "git",
                "-C",
                git_root,
                "rev-parse",
                "--abbrev-ref",
                "HEAD",
            }, { text = true }, function(branch_obj)
                if branch_obj.code ~= 0 then
                    run_callbacks(fallback)
                    return
                end

                local current_branch = vim.trim(branch_obj.stdout or "")
                if current_branch == "" or current_branch == "HEAD" then
                    run_callbacks(fallback)
                    return
                end

                vim.system({
                    "git",
                    "-C",
                    git_root,
                    "show-ref",
                    "--verify",
                    "--quiet",
                    "refs/remotes/origin/" .. current_branch,
                }, { text = true }, function(ref_obj)
                    if ref_obj.code == 0 then
                        finish("origin/" .. current_branch)
                        return
                    end

                    run_callbacks(fallback)
                end)
            end)
        end)
    end

    resolve_origin_head(function(origin_head)
        if origin_head and origin_head ~= "" then
            finish(origin_head)
            return
        end

        fallback_to_upstream_or_current_branch()
    end)
end

---@param base? string
---@param this_file? string
---@param callback fun(hunks: table[])
---@param opts? { git_root?: string, bufnr?: integer }
function M.get_diff_hunks(base, this_file, callback, opts)
    base = base or "HEAD"

    opts = opts or {}
    local git_root = opts.git_root or M.find_git_root(opts.bufnr)

    local cmd = { "git" }
    if git_root and git_root ~= "" then
        cmd[#cmd + 1] = "-C"
        cmd[#cmd + 1] = git_root
    end
    cmd[#cmd + 1] = "diff"
    cmd[#cmd + 1] = base
    cmd[#cmd + 1] = "--unified=0"
    if this_file and this_file ~= "" then
        local diff_file = this_file
        if git_root and git_root ~= "" and is_absolute_path(this_file) then
            diff_file = M.to_repo_relative_path(this_file, git_root)
        end
        cmd[#cmd + 1] = "--"
        cmd[#cmd + 1] = diff_file
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
