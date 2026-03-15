-- luacheck: globals describe it assert before_each after_each
local util_git = require("butterfly.util_git")
local split_diff_git = require("butterfly.split_diff.git")
local eq = assert.are.same

describe("util_git", function()
    local tmpdir
    local repo_dir
    local outside_dir
    local original_cwd

    local function run(cmd, cwd)
        local obj = vim.system(cmd, { cwd = cwd, text = true }):wait()
        assert.are.same(
            0,
            obj.code,
            table.concat(cmd, " ") .. "\n" .. (obj.stderr or "")
        )
        return vim.trim(obj.stdout or "")
    end

    local function write_file(path, lines)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile(lines, path)
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        tmpdir = vim.fn.tempname()
        repo_dir = tmpdir .. "/repo"
        outside_dir = tmpdir .. "/outside"
        vim.fn.mkdir(repo_dir, "p")
        vim.fn.mkdir(outside_dir, "p")

        run({ "git", "init" }, repo_dir)

        write_file(repo_dir .. "/src/example.lua", {
            "local function alpha()",
            "  return 1",
            "end",
        })

        run({ "git", "add", "." }, repo_dir)
        run({
            "git",
            "-c",
            "user.name=Butterfly Tests",
            "-c",
            "user.email=tests@example.com",
            "commit",
            "-m",
            "init",
        }, repo_dir)
    end)

    after_each(function()
        vim.cmd("silent! %bwipeout!")
        if original_cwd and original_cwd ~= "" then
            vim.api.nvim_set_current_dir(original_cwd)
        end
        if tmpdir and tmpdir ~= "" then
            vim.fn.delete(tmpdir, "rf")
        end
    end)

    it("finds git root from current buffer outside cwd", function()
        local file_path = repo_dir .. "/src/example.lua"

        vim.api.nvim_set_current_dir(outside_dir)
        vim.cmd("edit " .. vim.fn.fnameescape(file_path))

        eq(vim.fn.resolve(repo_dir), util_git.find_git_root(0))
    end)

    it("normalizes absolute paths to repo-relative paths", function()
        local file_path = repo_dir .. "/src/example.lua"

        eq(
            "src/example.lua",
            util_git.to_repo_relative_path(file_path, repo_dir)
        )
    end)

    it("gets diff hunks using the provided git root", function()
        local file_path = repo_dir .. "/src/example.lua"
        local hunks

        write_file(file_path, {
            "local function alpha()",
            "  return 2",
            "end",
        })

        vim.api.nvim_set_current_dir(outside_dir)
        util_git.get_diff_hunks("HEAD", file_path, function(result)
            hunks = result
        end, { git_root = repo_dir })

        assert(vim.wait(2000, function()
            return hunks ~= nil
        end))

        eq(1, #hunks)
        eq("src/example.lua", hunks[1].file)
        eq(2, hunks[1].line)
    end)

    it("gets split diff files using the provided git root", function()
        local entries
        local git_root

        write_file(repo_dir .. "/src/example.lua", {
            "local function alpha()",
            "  return 3",
            "end",
        })

        vim.api.nvim_set_current_dir(outside_dir)
        split_diff_git.get_diff_files(
            "HEAD",
            function(result, resolved_git_root)
                entries = result
                git_root = resolved_git_root
            end,
            { git_root = repo_dir }
        )

        assert(vim.wait(2000, function()
            return entries ~= nil
        end))

        eq(repo_dir, git_root)
        eq(1, #entries)
        eq("src/example.lua", entries[1].path)
        eq("M", entries[1].status)
    end)
end)
