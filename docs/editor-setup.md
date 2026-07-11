# Editor Setup

Kō provides editor support through the `ko-lsp` language server and a tree-sitter grammar. This guide covers setup for popular editors.

## Prerequisites

Build Kō and install the binaries:

```bash
git clone https://github.com/Adjanour/ko-language.git
cd ko-language
./build.sh
```

Add `ko-dist/bin` to your `PATH`:

```bash
export PATH="$PATH:/path/to/ko-language/ko-dist/bin"
```

Verify both binaries are available:

```bash
which ko
which ko-lsp
```

## VS Code

### Option 1: Install from dist

The distribution includes a pre-built extension. Install it from the `.vsix` file:

```bash
code --install-extension vscode-ko/ko-language-0.5.0.vsix
```

### Option 2: Install from source

1. Open VS Code
2. Run `Extensions: Install from VSIX...` from the Command Palette
3. Select `vscode-ko/ko-language-0.5.0.vsix`

### Features

- Syntax highlighting (TextMate grammar)
- Hover information (types)
- Go to definition
- Document symbols
- Diagnostics (parse and type errors with source locations)
- Auto-completion

The extension automatically finds `ko-lsp` if it's in your `PATH`.

## Neovim

### With nvim-treesitter (syntax highlighting)

1. Install the tree-sitter grammar. If Kō is in the nvim-treesitter parser list:

```vim
:TSInstall ko
```

If not yet in the official list, use the local grammar:

```lua
-- In your init.lua or after/ directory
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.ko = {
  install_info = {
    url = "/path/to/ko-language/tree-sitter-ko",
    files = { "src/parser.c" },
    generate_from_npm = true,
  },
  filetype = "ko",
}
```

Then run `:TSInstall ko`.

2. Add Kō queries. Create `~/.config/nvim/queries/ko/` and copy the query files:

```bash
mkdir -p ~/.config/nvim/queries/ko
cp tree-sitter-ko/queries/*.scm ~/.config/nvim/queries/ko/
```

### With nvim-lspconfig (language server)

Add to your Neovim config (init.lua):

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

-- Register ko-lsp if not already defined
if not configs.ko_lsp then
  configs.ko_lsp = {
    default_config = {
      cmd = { "ko-lsp" },
      filetypes = { "ko" },
      root_dir = lspconfig.util.root_pattern("*.ko"),
    },
  }
end

lspconfig.ko_lsp.setup({})
```

### With conform.nvim (formatting, optional)

Kō doesn't have an official formatter yet, but you can set up a no-op or use a future formatter:

```lua
require("conform").setup({
  formatters_by_ft = {
    ko = {},  -- add a formatter here when available
  },
})
```

## Vim

### With vim-lsp

Add to your `.vimrc`:

```vim
if executable('ko-lsp')
  au User lsp_setup call lsp#register_server({
    \ 'name': 'ko-lsp',
    \ 'cmd': {server_info -> ['ko-lsp']},
    \ 'whitelist': ['ko'],
    \ })
endif
```

### With CoC.nvim

Add to your `coc-settings.json`:

```json
{
  "languageserver": {
    "ko": {
      "command": "ko-lsp",
      "filetypes": ["ko"]
    }
  }
}
```

### Syntax highlighting

Use the tree-sitter grammar with `nvim-treesitter` (see Neovim section above), or use the TextMate grammar:

```vim
autocmd BufNewFile,BufRead *.ko setfiletype ko
" Place ko.tmLanguage.json from vscode-ko/syntaxes/ in your syntax dir
```

## Helix

Helix has built-in LSP support. Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "ko"
language-servers = ["ko-lsp"]

[language-server.ko-lsp]
command = "ko-lsp"
```

For syntax highlighting, Helix uses tree-sitter. Build and install the grammar:

```bash
cd tree-sitter-ko
tree-sitter build
# Copy the .so to Helix's runtime dir
mkdir -p ~/.config/helix/runtime/queries/ko
cp queries/*.scm ~/.config/helix/runtime/queries/ko/
cp ko.so ~/.config/helix/runtime/parser/
```

## Sublime Text

### LSP

1. Install the [LSP](https://packagecontrol.io/packages/LSP) package
2. Open Command Palette → `LSP: Enable Language Server in Project`
3. Select `ko-lsp`
4. Add to your LSP settings (`LSP-ko-lsp.sublime-settings`):

```json
{
  "command": ["ko-lsp"],
  "selector": "source.ko",
  "languageId": "ko"
}
```

### Syntax highlighting

Install the `Kō` package from Package Control, or manually add the TextMate grammar from `vscode-ko/syntaxes/ko.tmLanguage.json`.

## Emacs

### With lsp-mode

```elisp
(use-package lsp-mode
  :hook (ko-mode . lsp-deferred)
  :config
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection "ko-lsp")
                    :major-modes '(ko-mode)
                    :server-id 'ko-lsp)))
```

### With eglot

```elisp
(add-hook 'ko-mode-hook 'eglot-ensure)
```

Then add to `~/.config/eglot/eglot-ko.el`:

```elisp
(add-to-list 'eglot-server-programs
             '(ko-mode . ("ko-lsp")))
```

## Treesitter Grammar

The tree-sitter grammar lives in `tree-sitter-ko/`. To use it in any editor that supports tree-sitter:

### Build from source

```bash
cd tree-sitter-ko
npm install
npx tree-sitter generate
# Produces src/parser.c
```

### Query files

| File | Purpose |
|------|---------|
| `queries/highlights.scm` | Syntax highlighting |
| `queries/folds.scm` | Code folding |
| `queries/indents.scm` | Indentation rules |
| `queries/injections.scm` | Language injection (e.g., comments) |

## Troubleshooting

### LSP not starting

1. Verify `ko-lsp` is in your PATH: `which ko-lsp`
2. Test it directly: `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ko-lsp`
3. Check your editor's LSP logs for errors

### Syntax highlighting not working

1. Ensure `.ko` files are associated with the Kō filetype
2. For tree-sitter: verify the grammar is compiled (`ko.so` or `parser.c` exists)
3. For TextMate: ensure the grammar file is loaded by your editor

### Diagnostics not showing

1. Open a `.ko` file
2. Check that `ko-lsp` is running (status bar in most editors)
3. Errors appear as red underlines with hover text
