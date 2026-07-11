;Highlights for Kō

;Keywords
"import" @keyword
"as" @keyword
"package" @keyword
"module" @keyword
"pub" @keyword
"type" @keyword
"fn" @keyword
"let" @keyword
"if" @keyword
"then" @keyword
"else" @keyword
"match" @keyword
"in" @keyword
"ref" @keyword
"comptime" @keyword

;Builtin types
"Int" @type.builtin
"Float" @type.builtin
"Bool" @type.builtin
"String" @type.builtin
"Char" @type.builtin
"Unit" @type.builtin

;Constructors
(constructor_identifier) @type

;Functions
(function_definition
  name: (identifier) @function)

(function_definition
  return_type: (_) @type)

;Parameters
(function_definition
  parameter: (pattern) @parameter)

;Let bindings
(let_binding
  name: (identifier) @variable)

(let_binding
  type_annotation: (_) @type)

;Variables
(identifier) @variable

;Field access
(field_access) @property

(record_literal
  type: (constructor_identifier) @type)

(field_initializer
  name: (identifier) @property)

(field_declaration
  name: (identifier) @property)

;Patterns
(constructor_pattern
  name: (constructor_identifier) @constructor)

(record_pattern
  name: (constructor_identifier) @type)

(record_pattern_field
  name: (identifier) @property)

(wildcard) @variable.builtin

;Operators
"=" @operator
"==" @operator
"!=" @operator
"<" @operator
"<=" @operator
">" @operator
">=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"++" @operator
"||" @operator
"&&" @operator
"|>" @operator
":=" @operator
"->" @operator
"=>" @operator
"!" @operator
"\\" @operator

;Delimiters
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
"|" @punctuation.delimiter
":" @punctuation.delimiter
".." @punctuation.delimiter

;Literals
(integer) @number
(float) @float
(string) @string
(char) @character
(escape_sequence) @escape

;String interpolation
(string_interpolation
  "${" @punctuation.special
  "}" @punctuation.special) @embedded

;Comments
(line_comment) @comment
(block_comment) @comment
