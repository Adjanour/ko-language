// A Shiki TextMate grammar for Kō.
//
// Kō doesn't have an existing TextMate grammar to borrow — its editor tooling
// (tree-sitter-ko) uses a different, regex-incompatible grammar format, and
// the tree-sitter grammar itself documents some syntax (block comments,
// brace-delimited `match { }`, `//` comments) the compiler doesn't actually
// accept. Every rule below is checked against ko-zig/src/lexer.zig — the
// compiler's real tokenizer — not against tree-sitter-ko/grammar.js.
//
// Scope names follow standard TextMate conventions so Shiki's bundled themes
// (github-dark, github-light, ...) color it sensibly without a custom theme.

const identifier = '[a-z_][a-zA-Z0-9_-]*';
const constructorIdentifier = '[A-Z][a-zA-Z0-9_-]*';

export default {
  name: 'ko',
  scopeName: 'source.ko',
  patterns: [
    { include: '#comments' },
    { include: '#strings' },
    { include: '#chars' },
    { include: '#numbers' },
    { include: '#keywords-control' },
    { include: '#keywords' },
    { include: '#constants' },
    { include: '#builtin-types' },
    { include: '#function-definition' },
    { include: '#field-access' },
    { include: '#constructors' },
    { include: '#operators' },
    { include: '#punctuation' },
  ],
  repository: {
    comments: {
      patterns: [
        {
          name: 'comment.line.number-sign.ko',
          match: '#.*$',
        },
      ],
    },

    strings: {
      name: 'string.quoted.double.ko',
      begin: '"',
      end: '"',
      patterns: [
        {
          name: 'constant.character.escape.ko',
          match: "\\\\[nrt\\\\'\"]",
        },
      ],
    },

    chars: {
      name: 'string.quoted.single.ko',
      begin: "'",
      end: "'",
      patterns: [
        {
          name: 'constant.character.escape.ko',
          match: "\\\\[nrt\\\\'\"]",
        },
      ],
    },

    numbers: {
      patterns: [
        {
          name: 'constant.numeric.hex.ko',
          match: '\\b0[xX][0-9a-fA-F_]+\\b',
        },
        {
          name: 'constant.numeric.binary.ko',
          match: '\\b0[bB][01_]+\\b',
        },
        {
          name: 'constant.numeric.octal.ko',
          match: '\\b0[oO][0-7_]+\\b',
        },
        {
          name: 'constant.numeric.float.ko',
          match: '\\b[0-9][0-9_]*\\.[0-9][0-9_]*\\b',
        },
        {
          name: 'constant.numeric.decimal.ko',
          match: '\\b[0-9][0-9_]*\\b',
        },
      ],
    },

    // if / then / else / match: control flow, kept visually distinct from
    // declaration keywords the way most themes distinguish keyword.control.
    'keywords-control': {
      name: 'keyword.control.ko',
      match: '\\b(if|then|else|match)\\b',
    },

    keywords: {
      patterns: [
        {
          name: 'keyword.other.ko',
          match: '\\b(fn|let|type|import|package|pub|module|comptime|as|ref)\\b',
        },
        {
          name: 'keyword.operator.word.ko',
          match: '\\b(and|or|not)\\b',
        },
      ],
    },

    constants: {
      name: 'constant.language.boolean.ko',
      match: '\\b(true|false)\\b',
    },

    'builtin-types': {
      name: 'support.type.builtin.ko',
      match: '\\b(Int|Float|Bool|String|Char|Unit)\\b',
    },

    // `fn name ...` — the name right after `fn` is the function being
    // defined, so it earns entity.name.function instead of the generic
    // constructor/identifier treatment.
    'function-definition': {
      match: `(\\bfn\\b)\\s+(${identifier})`,
      captures: {
        1: { name: 'keyword.other.ko' },
        2: { name: 'entity.name.function.ko' },
      },
    },

    // `.field` — record field access.
    'field-access': {
      match: `(\\.)(${identifier})\\b`,
      captures: {
        1: { name: 'punctuation.accessor.ko' },
        2: { name: 'variable.other.property.ko' },
      },
    },

    // Capitalized identifiers double as type names and data constructors
    // (`Just`, `Nothing`, `Cons`, `Student` the record constructor, ...).
    constructors: {
      name: 'entity.name.type.ko',
      match: `\\b${constructorIdentifier}\\b`,
    },

    operators: {
      patterns: [
        {
          // Multi-character operators first so the alternation doesn't stop
          // early on a shared prefix (e.g. `=>` must win over `=`).
          name: 'keyword.operator.ko',
          match: '(\\|>|=>|->|==|!=|<=|>=|&&|\\|\\||:=|::)',
        },
        {
          name: 'keyword.operator.ko',
          match: '[+\\-*/%=<>!&|~?\\\\]',
        },
      ],
    },

    punctuation: {
      patterns: [
        {
          name: 'punctuation.bracket.ko',
          match: '[(){}\\[\\]]',
        },
        {
          name: 'punctuation.delimiter.ko',
          match: '[,;:.]',
        },
      ],
    },
  },
};
