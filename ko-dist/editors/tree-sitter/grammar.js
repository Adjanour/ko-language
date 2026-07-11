module.exports = grammar({
  name: 'ko',

  extras: $ => [
    /\s/,
    $.line_comment,
    $.block_comment,
  ],

  conflicts: $ => [
    [$.primary_expression, $.record_literal],
  ],

  rules: {
    source_file: $ => repeat($._definition),

    _definition: $ => choice(
      $.import_statement,
      $.package_definition,
      $.module_definition,
      $.function_definition,
      $.type_definition,
      $.let_binding,
      $.expression_statement,
    ),

    // ===== Top-level constructs =====

    import_statement: $ => seq(
      'import',
      field('path', $.import_path),
      optional(seq('.', '{', field('selective', $.selective_import), '}')),
      optional(seq('as', field('alias', $.identifier))),
    ),

    import_path: $ => prec.left(seq(
      choice($.identifier, $.constructor_identifier),
      repeat(seq('.', choice($.identifier, $.constructor_identifier))),
    )),

    selective_import: $ => seq(
      $.identifier,
      repeat(seq(',', $.identifier)),
    ),

    package_definition: $ => seq(
      'package',
      field('name', $.identifier),
    ),

    module_definition: $ => seq(
      optional('pub'),
      'module',
      field('name', choice($.identifier, $.constructor_identifier)),
      field('body', $.block),
    ),

    // ===== Type Definitions =====

    type_definition: $ => seq(
      optional('pub'),
      'type',
      field('name', choice($.identifier, $.constructor_identifier)),
      repeat(field('type_parameter', $.identifier)),
      '=',
      field('body', choice(
        $.sum_type_body,
        $.record_type_body,
      )),
    ),

    sum_type_body: $ => seq(
      $.type_constructor,
      repeat(seq('|', $.type_constructor)),
    ),

    type_constructor: $ => prec.left(seq(
      field('name', $.constructor_identifier),
      repeat(field('parameter', $.type_atom)),
    )),

    record_type_body: $ => seq(
      '{',
      optional(seq(
        $.field_declaration,
        repeat(seq(',', $.field_declaration)),
        optional(','),
      )),
      '}',
    ),

    field_declaration: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $.type_expression),
    ),

    // ===== Function Definitions =====

    function_definition: $ => seq(
      optional('pub'),
      'fn',
      field('name', $.identifier),
      repeat(field('parameter', $.pattern)),
      optional(seq(':', field('return_type', $.type_expression))),
      '=',
      field('body', $.expression),
    ),

    // ===== Let Bindings =====

    let_binding: $ => seq(
      optional('pub'),
      'let',
      field('name', $.identifier),
      optional(seq(':', field('type_annotation', $.type_expression))),
      '=',
      field('value', $.expression),
    ),

    expression_statement: $ => field('expression', $.expression),

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
      $.constructor_identifier,
      seq('(', $.type_expression, ')'),
      $.record_type_body,
    ),

    // ===== Patterns =====

    pattern: $ => choice(
      $.wildcard,
      $.constructor_pattern,
      $.record_pattern,
      $.tuple_pattern,
      $.identifier,
      $.integer,
      $.float,
      $.string,
      $.char,
      $.true,
      $.false,
    ),

    constructor_pattern: $ => prec.left(seq(
      field('name', $.constructor_identifier),
      repeat(field('argument', $.pattern_atom)),
    )),

    pattern_atom: $ => choice(
      $.wildcard,
      $.identifier,
      $.integer,
      $.float,
      $.string,
      $.char,
      $.true,
      $.false,
      seq('(', $.pattern, ')'),
    ),

    record_pattern: $ => seq(
      field('name', $.constructor_identifier),
      '{',
      optional(seq(
        $.record_pattern_field,
        repeat(seq(',', $.record_pattern_field)),
        optional(seq(',', '..')),
      )),
      '}',
    ),

    record_pattern_field: $ => seq(
      field('name', $.identifier),
      optional(seq('=', field('pattern', $.pattern))),
    ),

    tuple_pattern: $ => seq(
      '(',
      $.pattern,
      ',',
      $.pattern,
      repeat(seq(',', $.pattern)),
      ')',
    ),

    // ===== Expressions =====

    expression: $ => choice(
      $.if_expression,
      $.match_expression,
      $.let_expression,
      $.lambda,
      $.assign_expression,
      $.binary_expression,
      $.unary_expression,
      $.field_access,
      $.function_application,
      $.block,
      $.primary_expression,
    ),

    // ===== Block =====

    block: $ => seq(
      '{',
      repeat(seq($.statement, ';')),
      optional($.statement),
      '}',
    ),

    statement: $ => choice(
      $.let_binding,
      $.function_definition,
      $.type_definition,
      $.expression,
    ),

    // ===== If Expression =====

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

    // ===== Match Expression =====

    match_expression: $ => prec.right(seq(
      'match',
      field('value', $.primary_expression),
      '{',
      repeat(seq($.match_arm, ';')),
      optional($.match_arm),
      '}',
    )),

    match_arm: $ => seq(
      field('pattern', $.pattern),
      '=>',
      field('body', $.expression),
    ),

    // ===== Let Expression =====

    let_expression: $ => prec.right(seq(
      'let',
      field('name', $.identifier),
      optional(seq(':', field('type_annotation', $.type_expression))),
      '=',
      field('value', $.expression),
      'in',
      field('body', $.expression),
    )),

    // ===== Lambda =====

    lambda: $ => prec.right(seq(
      '\\',
      repeat(field('parameter', $.pattern)),
      '->',
      field('body', $.expression),
    )),

    // ===== Binary Expressions (precedence low → high) =====

    binary_expression: $ => {
      const table = [
        ['||', 1],
        ['&&', 2],
        ['==', 3], ['!=', 3],
        ['<', 4], ['>', 4], ['<=', 4], ['>=', 4],
        ['+', 5], ['-', 5], ['++', 5],
        ['*', 6], ['/', 6], ['%', 6],
        ['|>', 7],
      ];

      return choice(...table.map(([op, prec_val]) =>
        prec.left(prec_val, seq($.expression, op, $.expression))
      ));
    },

    // ===== Unary Expressions =====

    unary_expression: $ => choice(
      prec(8, seq('-', $.expression)),
      prec(8, seq('!', $.expression)),
      prec(8, seq('ref', $.expression)),
    ),

    // ===== Function Application =====

    function_application: $ => prec.left(9, seq(
      $.primary_expression,
      repeat1($.primary_expression),
    )),

    // ===== Field Access =====

    field_access: $ => prec.left(11, seq(
      $.primary_expression,
      '.',
      $.identifier,
    )),

    // ===== Primary Expressions =====

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
      $.tuple_literal,
      $.record_literal,
      seq('(', $.expression, ')'),
      $.comptime_expression,
    ),

    // ===== Record Literal =====

    record_literal: $ => seq(
      field('type', $.constructor_identifier),
      '{',
      optional(seq(
        $.field_initializer,
        repeat(seq(',', $.field_initializer)),
        optional(','),
      )),
      '}',
    ),

    field_initializer: $ => seq(
      field('name', $.identifier),
      '=',
      field('value', $.expression),
    ),

    // ===== Tuple Literal =====

    tuple_literal: $ => seq(
      '(',
      $.expression,
      ',',
      $.expression,
      repeat(seq(',', $.expression)),
      ')',
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

    // ===== Assign Expression =====

    assign_expression: $ => prec.right(10, seq(
      $.expression,
      ':=',
      $.expression,
    )),

    // ===== Comptime Expression =====

    comptime_expression: $ => seq(
      'comptime',
      $.expression,
    ),

    // ===== Literals =====

    integer: $ => /0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*/,

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

    escape_sequence: $ => /\\[nrt\\'"]/,

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
  },
});
