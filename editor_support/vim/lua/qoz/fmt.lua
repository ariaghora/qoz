-- Format-on-save for Qoz buffers. Pipes the buffer contents
-- through `qoz fmt --stdin <path>` on every BufWritePre and
-- replaces the buffer with the result. Cursor position is
-- preserved when the formatted text has at least as many lines
-- as the original cursor row.
--
-- Setup once at startup:
--   require("qoz.fmt").setup()
--
-- Options:
--   qoz_binary: path to the qoz compiler (default: ./qoz at the
--               repo root inferred from this file's location).
--   qoz_root:   QOZ_ROOT exported to the compiler subprocess.
--   silent:     when true, suppress notifications on format failure.

local M = {}

local function default_paths()
    local src = debug.getinfo(1, "S").source:sub(2)
    local repo_root = vim.fn.fnamemodify(src, ":h:h:h:h:h")
    return {
        qoz_binary = repo_root .. "/qoz",
        qoz_root   = repo_root,
    }
end

local function format_buffer(bufnr, opts)
    local d = default_paths()
    local qoz_bin  = opts.qoz_binary or d.qoz_binary
    local qoz_root = opts.qoz_root   or d.qoz_root
    if vim.fn.executable(qoz_bin) == 0 then
        if not opts.silent then
            vim.notify("qoz-fmt: " .. qoz_bin .. " not found", vim.log.levels.WARN)
        end
        return
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path == "" then return end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local input = table.concat(lines, "\n")
    if not input:match("\n$") then input = input .. "\n" end

    local result = vim.system(
        { qoz_bin, "fmt", "--stdin", path },
        { stdin = input, env = vim.tbl_extend("force", vim.fn.environ(), { QOZ_ROOT = qoz_root }), text = true }
    ):wait()

    if result.code ~= 0 then
        if not opts.silent then
            vim.notify("qoz-fmt failed:\n" .. (result.stderr or "") .. (result.stdout or ""), vim.log.levels.ERROR)
        end
        return
    end
    local out = result.stdout or ""
    if out == "" then return end
    if out:sub(-1) == "\n" then out = out:sub(1, -2) end
    local new_lines = vim.split(out, "\n", { plain = true })

    local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local equal = #cur_lines == #new_lines
    if equal then
        for i = 1, #cur_lines do
            if cur_lines[i] ~= new_lines[i] then equal = false; break end
        end
    end
    if equal then return end

    local view = vim.fn.winsaveview()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
    pcall(vim.fn.winrestview, view)
end

function M.setup(opts)
    opts = opts or {}
    local group = vim.api.nvim_create_augroup("QozFmt", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
        group   = group,
        pattern = "*.qoz",
        callback = function(ev) format_buffer(ev.buf, opts) end,
    })
end

return M
