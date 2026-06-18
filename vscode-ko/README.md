# Kō Language Support for VS Code

Syntax highlighting and language support for the Kō programming language.

## Features

- **Syntax Highlighting**: Full syntax highlighting for Kō code
- **Keyword Completion**: Auto-complete for keywords and built-in functions
- **Hover Documentation**: Hover over keywords to see documentation

## Installation

### From VSIX

1. Run `code --install-extension ko-language-0.1.0.vsix`

### From Source

1. Install `@vscode/vsce`: `npm install -g @vscode/vsce`
2. Run `vsce package` in this directory
3. Run `code --install-extension ko-language-0.1.0.vsix`

## Supported Syntax

- Keywords: `fn`, `let`, `if`, `then`, `else`, `match`, `type`, `in`
- Built-in functions: `print`, `println`, `inspect`, `panic`
- Types and constructors (uppercase identifiers)
- Hex (`0xFF`), binary (`0b1010`), and decimal numbers
- Strings and characters with escape sequences
- Single-line (`//`, `#`) and block (`/* */`) comments
- Operators: arithmetic, comparison, logical
