# Tree-sitter & VSCode Extensions — Concepts Guide

How we built syntax highlighting and editor support for Kō.

## Tree-sitter

### What is it?

Tree-sitter is a parser generator. You write a grammar in JavaScript (`grammar.js`), it generates a C parser that builds a syntax tree from your code. Fast, incremental, error-tolerant.

### Why use it?

- **Incremental** — only re-parses what changed, not the whole file
- **Error-tolerant** — still parses code with syntax errors (great for editors)
- **Fast** — written in C, parses millions of lines per second
- **Portable** — generates parsers for C, Rust, JS, Python, etc.

### How it works

1. Write grammar in `grammar.js`
2. Run `tree-sitter generate` → generates C parser
3. Parser reads code → builds concrete syntax tree (CST)
4. Editor uses tree for highlighting, queries, etc.

### Our grammar (`tree-sitter-ko/grammar.js`)

```javascript
module.exports = grammar({
  name: 'ko',

  rules: {
    source_file: $ => repeat($._definition),

    _definition: $ => choice(
      $.type_definition,
      $.function_definition,
      $.let_binding,
    ),

    function_definition: $ => seq(
      'fn',
      field('name', $.identifier),
      repeat(field('parameter', $.identifier)),
      '=',
      field('body', $.expression),
    ),

    // ... more rules
  }
});
```

Key concepts:
- **Rules** define syntax patterns
- **`seq()`** = sequence of items
- **`choice()`** = one of these options
- **`repeat()`** = zero or more
- **`repeat1()`** = one or more
- **`optional()`** = zero or one
- **`prec()`** = precedence (resolves ambiguity)
- **`field()`** = named part of the node

### Conflicts

Tree-sitter complains when grammar is ambiguous. We hit a few:

1. **Dangling else** — `if ... then if ... then ... else ...`
   - Fix: `prec.right()` on if_expression

2. **Operator precedence** — `a + b * c`
   - Fix: table of operators with precedence levels

3. **Recursive expressions** — binary expressions referencing themselves
   - Fix: use `$.expression` directly instead of separate `_expression` rule

### Testing

```bash
tree-sitter generate      # generate parser
tree-sitter test          # run test cases
tree-sitter parse file.ko # parse a file
tree-sitter playground    # interactive browser
```

### Queries

Tree-sitter supports queries for syntax highlighting:

```scheme
; highlights.scm
(function_definition
  name: (identifier) @function)

(type_definition
  name: (constructor_identifier) @type)

(comment) @comment
```

VSCode doesn't use these directly — it uses TextMate grammars instead. But tree-sitter queries are useful for other editors (Neovim, Helix, etc.).

---

## VSCode Extensions

### Structure

```
vscode-ko/
├── package.json              # Extension manifest
├── language-configuration.json  # Language settings
├── syntaxes/
│   └── ko.tmLanguage.json    # TextMate grammar
├── extension.js              # Activation logic
└── icon.png                  # File icon
```

### package.json

The manifest declares what your extension contributes:

```json
{
  "contributes": {
    "languages": [{
      "id": "ko",
      "extensions": [".ko"],
      "icon": { "light": "./icon.png", "dark": "./icon.png" }
    }],
    "grammars": [{
      "language": "ko",
      "scopeName": "source.ko",
      "path": "./syntaxes/ko.tmLanguage.json"
    }]
  }
}
```

- **`languages`** — registers `.ko` files as Kō language
- **`grammars`** — attaches TextMate grammar to the language
- **`icon`** — file icon (shown if theme doesn't override)

### TextMate Grammars

VSCode uses TextMate grammars for syntax highlighting. Pattern-based regex matching:

```json
{
  "patterns": [
    {
      "name": "keyword.control.ko",
      "match": "\\b(if|then|else|match|let|in|fn|type)\\b"
    },
    {
      "name": "entity.name.type.constructor.ko",
      "match": "\\b[A-Z][a-zA-Z0-9_]*\\b"
    }
  ]
}
```

Scope names map to themes:
- `keyword.control` → purple/blue
- `string` → green
- `comment` → gray
- `entity.name.type` → yellow/teal
- `constant.numeric` → orange

### language-configuration.json

Controls editor behavior:

```json
{
  "comments": { "lineComment": "//", "blockComment": ["/*", "*/"] },
  "brackets": [["(", ")"], ["[", "]"]],
  "autoClosingPairs": [
    { "open": "(", "close": ")" }
  ],
  "indentationRules": {
    "increaseIndentPattern": "^\\s*(fn|let|match)\\b.*=\\s*$"
  }
}
```

### Extension API Features

We registered these providers in `extension.js`:

| Provider | What it does |
|----------|--------------|
| `CompletionItemProvider` | Autocomplete (keywords, builtins, snippets) |
| `HoverProvider` | Hover tooltips with docs |
| `DocumentSymbolProvider` | Outline view (functions, types) |
| `FoldingRangeProvider` | Foldable regions |
| `BracketMatchingProvider` | Highlight matching brackets |

### Snippets

Templates with tab stops:

```javascript
item.insertText = new vscode.SnippetString(
  'fn ${1:name} ${2:params} = ${3:body}'
);
// Tab stops: 1=name, 2=params, 3=body
```

### Building & Installing

```bash
# Install vsce (VSCode Extension CLI)
npm install -g @vscode/vsce

# Package extension
vsce package --allow-missing-repository

# Install locally
code --install-extension ko-language-0.1.0.vsix --force
```

### Publishing

1. Create publisher account at marketplace.visualstudio.com
2. `vsce publish`

---

## How They Connect

```
Source code (.ko)
       ↓
   Tree-sitter (grammar.js)
       ↓
   Syntax tree (for editors that support it)
       ↓
   TextMate grammar (for VSCode)
       ↓
   Highlighted code
```

Tree-sitter is the "real" parser. TextMate is a simpler regex-based fallback for VSCode. Both do syntax highlighting, but tree-sitter is smarter (understands structure, not just patterns).

For a production language, you'd want both:
- Tree-sitter for Neovim, Helix, Zed, etc.
- TextMate for VSCode (or use vscode-tree-sitter extension)

---

## Quick Reference

### Tree-sitter CLI
```bash
tree-sitter init          # setup project
tree-sitter generate      # generate parser
tree-sitter test          # run tests
tree-sitter parse <file>  # parse file
tree-sitter playground    # browser REPL
```

### VSCode Extension
```bash
vsce package              # build .vsix
code --install-extension  # install
code --uninstall-extension # uninstall
```

### Useful Links
- Tree-sitter: https://tree-sitter.github.io/tree-sitter/
- VSCode Extension API: https://code.visualstudio.com/api
- TextMate Grammars: https://macromates.com/manual/en/language_grammar
