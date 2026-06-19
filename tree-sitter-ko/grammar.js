module.exports = grammar({
  name: 'ko',

  extras: $ => [
    /\s/,
    $.line_comment,
    $.block_comment,
  ],

  conflicts: $ => [
    [$.function_definition, $.primary_expression],
  ],

  rules: {
    source_file: $ => repeat($._definition),

    _definition: $ => choice(
      $.type_definition,
      $.function_definition,
      $.let_binding,
      $.expression_statement,
    ),

    // ===== Type Definitions =====
    type_definition: $ => seq(
      'type',
      field('name', $.identifier),
      '=',
      $.type_constructor,
      repeat(seq('|', $.type_constructor)),
    ),

    type_constructor: $ => seq(
      field('name', $.constructor_identifier),
      repeat(field('slot', '*')),
    ),

    // ===== Type Expressions =====
    type_expression: $ => choice(
      $.type_arrow,
      $.type_atom,
    ),

    type_arrow: $ => prec.right(seq(
      $.type_atom,
      '->',
      $.type_expression,
    )),

    type_atom: $ => choice(
      'Int',
      'Float',
      'Bool',
      'String',
      'Char',
      'Unit',
      $.identifier,
      seq('(', $.type_expression, ')'),
    ),

    // ===== Function Definitions =====
    function_definition: $ => choice(
      // With type annotation only (no params/body)
      seq(
        'fn',
        field('name', $.identifier),
        ':',
        field('type_annotation', $.type_expression),
      ),
      // With params, optional type annotation, and body
      seq(
        'fn',
        field('name', $.identifier),
        repeat(field('parameter', $.identifier)),
        optional(seq(':', field('type_annotation', $.type_expression))),
        '=',
        field('body', $.expression),
      ),
    ),

    let_binding: $ => seq(
      'let',
      field('name', $.identifier),
      '=',
      field('value', $.expression),
    ),

    expression_statement: $ => field('expression', $.expression),

    // ===== Patterns =====
    pattern: $ => choice(
      $.constructor_pattern,
      $.identifier,
      $.wildcard,
      $.integer,
      $.float,
      $.string,
      $.char,
      $.true,
      $.false,
    ),

    constructor_pattern: $ => prec.left(seq(
      field('name', $.constructor_identifier),
      repeat(field('argument', $.pattern)),
    )),

    // ===== Expressions =====
    expression: $ => choice(
      $.if_expression,
      $.match_expression,
      $.let_expression,
      $.lambda,
      $.binary_expression,
      $.unary_expression,
      $.function_application,
      $.primary_expression,
    ),

    if_expression: $ => prec.right(seq(
      'if',
      field('condition', $.expression),
      'then',
      field('consequence', $.expression),
      optional(seq(
        'else',
        field('alternative', $.expression),
      )),
    )),

    match_expression: $ => prec.right(seq(
      'match',
      field('value', $.expression),
      $.newline,
      repeat1($.match_arm),
    )),

    match_arm: $ => seq(
      field('pattern', $.pattern),
      '->',
      field('body', $.expression),
    ),

    let_expression: $ => seq(
      'let',
      field('name', $.identifier),
      '=',
      field('value', $.expression),
      'in',
      field('body', $.expression),
    ),

    // ===== Lambda Expression =====
    lambda: $ => prec.right(seq(
      '\\',
      repeat(field('parameter', $.identifier)),
      '->',
      field('body', $.expression),
    )),

    binary_expression: $ => {
      const table = [
        ['||', 1],
        ['&&', 2],
        ['==', 3], ['!=', 3],
        ['<', 4], ['>', 4], ['<=', 4], ['>=', 4],
        ['+', 5], ['-', 5], ['++', 5],
        ['*', 6], ['/', 6], ['%', 6],
      ];

      return choice(...table.map(([op, prec_val]) =>
        prec.left(prec_val, seq($.expression, op, $.expression))
      ));
    },

    unary_expression: $ => choice(
      prec(7, seq('-', $.expression)),
      prec(7, seq('!', $.expression)),
    ),

    function_application: $ => prec.left(8, seq(
      $.primary_expression,
      repeat1($.primary_expression),
    )),

    primary_expression: $ => choice(
      $.identifier,
      $.constructor_identifier,
      $.integer,
      $.float,
      $.string,
      $.char,
      $.true,
      $.false,
      $.wildcard,
      $.list_literal,
      seq('(', $.expression, ')'),
      $.ref_expression,
      $.comptime_expression,
    ),

    // ===== Ref Cell Expressions =====
    ref_expression: $ => prec.left(seq(
      'ref',
      $.expression,
    )),

    // ===== Comptime Expression =====
    comptime_expression: $ => seq(
      'comptime',
      $.expression,
    ),

    // ===== List Literal =====
    list_literal: $ => seq(
      '[',
      optional(seq(
        $.expression,
        repeat(seq(',', $.expression)),
      )),
      ']',
    ),

    // ===== Literals =====
    integer: $ => /0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*/,

    float: $ => /[0-9][0-9_]*\.[0-9][0-9_]*/,

    string: $ => seq(
      '"',
      repeat(choice(
        /[^"\\]/,
        $.escape_sequence,
        $.string_interpolation,
      )),
      '"',
    ),

    string_interpolation: $ => seq(
      '${',
      $.expression,
      '}',
    ),

    char: $ => seq(
      "'",
      choice(
        /[^'\\]/,
        $.escape_sequence,
      ),
      "'",
    ),

    escape_sequence: $ => /\\[ntr\\'"]/,

    // ===== Identifiers =====
    identifier: $ => /[a-z][a-z0-9_-]*/,

    constructor_identifier: $ => /[A-Z][a-zA-Z0-9_-]*/,

    // ===== Keywords =====
    true: $ => 'true',
    false: $ => 'false',
    wildcard: $ => '_',

    // ===== Comments =====
    line_comment: $ => token(seq(
      choice('#', '//'),
      /[^\n]*/,
    )),

    block_comment: $ => token(seq(
      '/*',
      /[^*]*\*+([^/*][^*]*\*+)*/,
      '/',
    )),

    // ===== Whitespace =====
    newline: $ => /\n/,
  },
});
