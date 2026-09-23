# Kō Language Support for VS Code

Syntax highlighting, diagnostics, and LSP-powered editing for the Kō programming language.

## Features

- **Syntax highlighting** — keywords, constructors, float dotted operators (`+.`, `*.`, …), numbers, strings, doc comments
- **Live diagnostics** — parse and type errors with squiggles as you type
- **Hover** — inferred types for your functions (with `#` doc comments), signatures for builtins (`Int.toString`, `Float.sqrt`, …), keyword docs; qualified names like `Int.toString` resolve through the qualifier
- **Completion** — prefix-filtered functions, types, modules, imports, builtins (with signatures) and keywords (with docs)
- **Go to definition** — jumps to the exact name, not line 0
- **Find references** — all whole-word uses in the file
- **Document symbols + imports** — outline view with real ranges
- **Commands** — `Kō: Run Current File` (editor title bar ▶ for `.ko` files), `Kō: Restart Language Server`

## Requirements

The extension launches `ko-lsp` from your `PATH`. If it is not on `PATH`, set
`ko.languageServer.path` to the binary (e.g. `<repo>/ko-zig/zig-out/bin/ko-lsp`).
`Kō: Run Current File` uses the `ko` binary from `ko.compiler.path` (default: `ko` on `PATH`).

## Extension Settings

| Setting | Default | Purpose |
|---|---|---|
| `ko.languageServer.path` | `""` (auto-discover) | Path to `ko-lsp` |
| `ko.languageServer.args` | `[]` | Extra `ko-lsp` arguments |
| `ko.compiler.path` | `"ko"` | `ko` binary for Run Current File |

Changing any `ko.languageServer.*` setting restarts the server automatically.

## Installation

### From VSIX

```bash
code --install-extension ko-language-0.6.0.vsix
```

### From source

```bash
npm install -g @vscode/vsce
vsce package   # in this directory
code --install-extension ko-language-0.6.0.vsix
```

## Known limitations

- Single-file analysis: no cross-file go-to-definition or import navigation yet.
- `ko-lsp` is reached via stdio; very large files re-analyze fully on each keystroke.
