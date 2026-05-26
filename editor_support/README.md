# Editor support

A Vim runtime plugin lives at [vim/](vim/). Neovim consumes the same
files, so there is one plugin and one install procedure regardless of
which of the two editors you run.

Layout:

```
editor_support/vim/
  ftdetect/qoz.vim    map *.qoz to filetype qoz
  syntax/qoz.vim      highlight definitions
  ftplugin/qoz.vim    commentstring and 4-space indentation
```

## Install

### Manual

```
mkdir -p ~/.config/nvim/{ftdetect,syntax,ftplugin}    # Neovim
mkdir -p ~/.vim/{ftdetect,syntax,ftplugin}            # Vim
```

Copy or symlink each file into the corresponding subdirectory of
`~/.config/nvim/` (Neovim) or `~/.vim/` (Vim). Opening a `.qoz` file
then triggers the filetype and the syntax module loads.

### lazy.nvim

```lua
return {
  {
    dir = "/absolute/path/to/qoz-odin/editor_support/vim",
    name = "qoz.vim",
    ft = "qoz",
    init = function()
      vim.filetype.add({ extension = { qoz = "qoz" } })
    end,
  },
}
```

### Plug-style managers

Most plugin managers can point at a subdirectory of a checked-out
repo. vim-plug example:

```
Plug 'your-fork/qoz-odin', { 'rtp': 'editor_support/vim' }
```

## What is highlighted

- Keywords: `let`, `var`, `return`, `defer`, `if`, `elif`, `else`,
  `match`, `while`, `for`, `in`, `import`, `external`, `as`, `new`,
  `type`.
- Compile-time directives: `#if`, `#elif`, `#else`, `#link_library`,
  `#link_framework`, `#link_path`, `#load_string`.
- Primitive types: `i8`..`i64`, `u8`..`u64`, `f32`, `f64`, `bool`,
  `char`, `string`, `cstring`, `void`, `unit`.
- Numeric literals including `0x`, `0b`, `0o` prefixes and `_`
  separators.
- Double-quoted strings, backtick interpolation with `{expr}` slots,
  character literals, escape sequences, `{{` / `}}` brace escapes.
- `@link_name` and `@operator` attributes.
- Line and block comments with `TODO` / `FIXME` recognition.

## Language server (Neovim)

The Qoz language server is a separate binary built from the same
repo. Build steps:

```
make                                  # builds ./qoz
./qoz build editor_support/lsp_server # builds editor_support/lsp_server/lsp_server.bin
```

The server reads JSON-RPC frames over stdio and supports:

- `textDocument/publishDiagnostics` from parse and type-check
  output. The server shells out to `qoz check --stdin` with the
  unsaved buffer piped in.
- `textDocument/definition` for buffer-local and cross-package
  symbols.
- `textDocument/hover` showing the declaration's source line.
- `textDocument/completion` for top-level declarations, Qoz
  keywords, and dotted package members (`strings.<TAB>`).

A small Lua module at `editor_support/vim/lua/qoz/lsp.lua`
attaches the server to every Qoz buffer in Neovim 0.10+. Once
the plugin is on `runtimepath`:

```lua
require("qoz.lsp").setup()
```

The defaults resolve `lsp_server.bin`, the `qoz` binary, and
`QOZ_ROOT` from the repository root next to the Lua module.
Override any of them with explicit paths:

```lua
require("qoz.lsp").setup({
  lsp_server_path = "/abs/path/to/lsp_server.bin",
  qoz_binary      = "/abs/path/to/qoz",
  qoz_root        = "/abs/path/to/qoz-odin",
})
```

With lazy.nvim:

```lua
return {
  {
    dir = "/absolute/path/to/qoz-odin/editor_support/vim",
    name = "qoz.vim",
    ft = "qoz",
    config = function() require("qoz.lsp").setup() end,
  },
}
```

After opening a `.qoz` file, `:checkhealth vim.lsp` or `:LspInfo`
(if you have nvim-lspconfig) lists a client named `qoz` attached
to the buffer. Built-in keymaps work once the client attaches:
`gd` for goto definition, `K` for hover, and `<C-x><C-o>` for
omni-completion.

## Treesitter

A Treesitter grammar would give finer-grained highlighting and
incremental updates. It is not in this directory yet. The Vim regex
syntax above is correct for the language as it stands, and a
grammar is a separate project.
