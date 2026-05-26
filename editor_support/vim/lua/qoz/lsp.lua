-- Neovim 0.10+ LSP client for the Qoz language server.
--
-- Call require("qoz.lsp").setup() once during startup (or rely on
-- the autocommand the plugin registers when loaded via :source or
-- a plugin manager). The setup attaches the LSP to every Qoz
-- buffer using vim.lsp.start, which deduplicates clients per
-- root_dir.
--
-- Two paths the user can override:
--   * lsp_server_path: the lsp_server.bin built from
--     editor_support/lsp_server.
--   * qoz_binary: the qoz compiler the language server shells out
--     to for diagnostics. Exported to the server as LSP_QOZ_PATH.
--     QOZ_ROOT is also passed through so import resolution works.

local M = {}

local function find_root(bufnr)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    if fname == "" then return vim.fn.getcwd() end
    -- Walk up looking for a Makefile or SPEC.md. Falls back to the
    -- file's directory.
    local dir = vim.fs.dirname(fname)
    local marker = vim.fs.find({ "SPEC.md", "Makefile", ".git" }, {
        upward = true,
        path = dir,
    })[1]
    if marker then return vim.fs.dirname(marker) end
    return dir
end

local function default_paths()
    local src = debug.getinfo(1, "S").source:sub(2)
    -- src is .../editor_support/vim/lua/qoz/lsp.lua. The repo root
    -- is four parents up.
    local repo_root = vim.fn.fnamemodify(src, ":h:h:h:h:h")
    return {
        lsp_server_path = repo_root .. "/editor_support/lsp_server/lsp_server.bin",
        qoz_binary      = repo_root .. "/qoz",
        qoz_root        = repo_root,
    }
end

function M.start(opts)
    opts = opts or {}
    local d = default_paths()
    local server   = opts.lsp_server_path or d.lsp_server_path
    local qoz_bin  = opts.qoz_binary      or d.qoz_binary
    local qoz_root = opts.qoz_root        or d.qoz_root

    if vim.fn.executable(server) == 0 then
        vim.notify(
            "qoz-lsp: server binary not found at " .. server ..
            "\nBuild it with: ./qoz build editor_support/lsp_server",
            vim.log.levels.WARN
        )
        return
    end

    vim.lsp.start({
        name = "qoz",
        cmd  = { server },
        cmd_env = {
            LSP_QOZ_PATH = qoz_bin,
            QOZ_ROOT     = qoz_root,
        },
        root_dir = find_root(0),
    })
end

function M.setup(opts)
    local group = vim.api.nvim_create_augroup("QozLsp", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
        group   = group,
        pattern = "qoz",
        callback = function() M.start(opts) end,
    })
end

return M
