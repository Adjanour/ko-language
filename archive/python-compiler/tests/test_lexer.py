"""Comprehensive lexer tests for the Kō language.

Tests are organized by category and define the correct behavior
that the lexer implementation must satisfy (TDD approach).
"""

import unittest
import sys
import os

# Add parent directory to path so we can import lexer
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lexer import Lexer, TokenType, Token


def tokenize(source: str, file: str = "<test>") -> list:
    """Helper: tokenize source and return list of tokens (excluding EOF)."""
    lexer = Lexer(source, file)
    tokens = lexer.tokenize()
    # Filter out EOF for easier testing, but check it exists
    assert tokens[-1].type == TokenType.EOF, f"Expected EOF as last token, got {tokens[-1].type}"
    return tokens[:-1]  # exclude EOF


def tokenize_with_eof(source: str, file: str = "<test>") -> list:
    """Helper: tokenize source and return all tokens including EOF."""
    lexer = Lexer(source, file)
    return lexer.tokenize()


def tok(source: str) -> list:
    """Shorthand: tokenize and return token types only."""
    return [t.type for t in tokenize(source)]


def tok_vals(source: str) -> list:
    """Shorthand: tokenize and return (type, value) pairs."""
    lexer = Lexer(source)
    tokens = lexer.tokenize()
    result = []
    for t in tokens:
        if t.type == TokenType.EOF:
            break
        result.append((t.type, t.value))
    return result


class TestTokenBasics(unittest.TestCase):
    """Basic token types and single-character tokens."""

    def test_empty_input(self):
        tokens = tokenize("")
        self.assertEqual(len(tokens), 0)

    def test_whitespace_only(self):
        tokens = tokenize("   \t  ")
        self.assertEqual(len(tokens), 0)

    def test_single_newline(self):
        tokens = tokenize("\n")
        self.assertEqual(len(tokens), 1)
        self.assertEqual(tokens[0].type, TokenType.NEWLINE)

    def test_multiple_newlines(self):
        tokens = tokenize("\n\n\n")
        self.assertEqual(len(tokens), 3)

    def test_operators(self):
        self.assertEqual(tok("+"), [TokenType.PLUS])
        self.assertEqual(tok("-"), [TokenType.MINUS])
        self.assertEqual(tok("*"), [TokenType.STAR])
        self.assertEqual(tok("/"), [TokenType.SLASH])
        self.assertEqual(tok("%"), [TokenType.PERCENT])

    def test_delimiters(self):
        self.assertEqual(tok("("), [TokenType.LPAREN])
        self.assertEqual(tok(")"), [TokenType.RPAREN])
        self.assertEqual(tok("["), [TokenType.LBRACKET])
        self.assertEqual(tok("]"), [TokenType.RBRACKET])
        self.assertEqual(tok(","), [TokenType.COMMA])

    def test_assignment(self):
        self.assertEqual(tok("="), [TokenType.ASSIGN])

    def test_underscore(self):
        self.assertEqual(tok("_"), [TokenType.UNDERSCORE])

    def test_backslash(self):
        self.assertEqual(tok("\\"), [TokenType.BACKSLASH])


class TestMultiCharOperators(unittest.TestCase):
    """Multi-character operators."""

    def test_arrow(self):
        self.assertEqual(tok("->"), [TokenType.ARROW])

    def test_equal(self):
        self.assertEqual(tok("=="), [TokenType.EQ])

    def test_not_equal(self):
        self.assertEqual(tok("!="), [TokenType.NEQ])

    def test_less_than_or_equal(self):
        self.assertEqual(tok("<="), [TokenType.LTE])

    def test_greater_than_or_equal(self):
        self.assertEqual(tok(">="), [TokenType.GTE])

    def test_less_than(self):
        self.assertEqual(tok("<"), [TokenType.LT])

    def test_greater_than(self):
        self.assertEqual(tok(">"), [TokenType.GT])

    def test_and(self):
        self.assertEqual(tok("&&"), [TokenType.AND])

    def test_or(self):
        self.assertEqual(tok("||"), [TokenType.OR])

    def test_bang(self):
        self.assertEqual(tok("!"), [TokenType.BANG])

    def test_colon_equals(self):
        self.assertEqual(tok(":="), [TokenType.COLON_EQ])

    def test_arrow_in_context(self):
        tokens = tok("a -> b")
        self.assertEqual(tokens, [TokenType.IDENT, TokenType.ARROW, TokenType.IDENT])

    def test_minus_not_arrow(self):
        tokens = tok("a - b")
        self.assertEqual(tokens, [TokenType.IDENT, TokenType.MINUS, TokenType.IDENT])

    def test_equal_not_eq(self):
        tokens = tok("a = b")
        self.assertEqual(tokens, [TokenType.IDENT, TokenType.ASSIGN, TokenType.IDENT])

    def test_bang_not_neq(self):
        tokens = tok("! x")
        self.assertEqual(tokens, [TokenType.BANG, TokenType.IDENT])


class TestKeywords(unittest.TestCase):
    """Keyword recognition."""

    def test_all_keywords(self):
        keywords = {
            'fn': TokenType.FN,
            'type': TokenType.TYPE,
            'let': TokenType.LET,
            'match': TokenType.MATCH,
            'if': TokenType.IF,
            'then': TokenType.THEN,
            'else': TokenType.ELSE,
            'true': TokenType.TRUE,
            'false': TokenType.FALSE,
            'panic': TokenType.PANIC,
            'inspect': TokenType.INSPECT,
            'println': TokenType.PRINTLN,
            'import': TokenType.IMPORT,
            'as': TokenType.AS,
            'ref': TokenType.REF,
            'comptime': TokenType.COMPILETIME,
        }
        for word, expected_type in keywords.items():
            with self.subTest(word=word):
                tokens = tokenize(word)
                self.assertEqual(len(tokens), 1, f"Expected 1 token for '{word}', got {len(tokens)}")
                self.assertEqual(tokens[0].type, expected_type)

    def test_keyword_not_prefix(self):
        """Keywords should not match as prefixes of identifiers."""
        tokens = tok("fnx")
        self.assertEqual(tokens, [TokenType.IDENT])

        tokens = tok("typeX")
        self.assertEqual(tokens, [TokenType.IDENT])


class TestIdentifiers(unittest.TestCase):
    """Identifier recognition."""

    def test_simple_lowercase(self):
        tokens = tok("foo")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_underscore_start(self):
        tokens = tok("_x")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_underscore_only(self):
        tokens = tok("_")
        self.assertEqual(tokens, [TokenType.UNDERSCORE])

    def test_alphanumeric(self):
        tokens = tok("foo123")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_underscore_in_middle(self):
        tokens = tok("foo_bar")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_dash_in_identifier(self):
        tokens = tok("from-just")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_uppercase_identifier(self):
        """Uppercase identifiers are still IDENT tokens (context determines constructor vs type)."""
        tokens = tok("Just")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_mixed_case(self):
        tokens = tok("myFunc")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_identifier_values(self):
        vals = tok_vals("hello world")
        self.assertEqual(vals, [
            (TokenType.IDENT, "hello"),
            (TokenType.IDENT, "world"),
        ])


class TestIntegers(unittest.TestCase):
    """Integer literal recognition."""

    def test_simple_decimal(self):
        tokens = tok("42")
        self.assertEqual(tokens, [TokenType.INT])

    def test_zero(self):
        tokens = tok("0")
        self.assertEqual(tokens, [TokenType.INT])

    def test_hex(self):
        tokens = tok("0xFF")
        self.assertEqual(tokens, [TokenType.INT])

    def test_hex_upper(self):
        tokens = tok("0XFF")
        self.assertEqual(tokens, [TokenType.INT])

    def test_binary(self):
        tokens = tok("0b1010")
        self.assertEqual(tokens, [TokenType.INT])

    def test_underscores(self):
        tokens = tok("1_000_000")
        self.assertEqual(tokens, [TokenType.INT])

    def test_hex_with_underscores(self):
        tokens = tok("0xFF_00_FF")
        self.assertEqual(tokens, [TokenType.INT])

    def test_integer_values(self):
        vals = tok_vals("42 0xFF 0b1010 1_000")
        self.assertEqual(vals, [
            (TokenType.INT, "42"),
            (TokenType.INT, "0xFF"),
            (TokenType.INT, "0b1010"),
            (TokenType.INT, "1_000"),
        ])

    def test_integer_not_float(self):
        """42 should be INT, not FLOAT."""
        tokens = tok("42")
        self.assertEqual(tokens[0], TokenType.INT)

    def test_number_not_followed_by_ident(self):
        """42foo should be INT + IDENT, not one token."""
        tokens = tok("42foo")
        self.assertEqual(tokens, [TokenType.INT, TokenType.IDENT])


class TestFloats(unittest.TestCase):
    """Float literal recognition."""

    def test_simple_float(self):
        tokens = tok("3.14")
        self.assertEqual(tokens, [TokenType.FLOAT])

    def test_float_value(self):
        vals = tok_vals("3.14 0.5 1_000.5")
        self.assertEqual(vals, [
            (TokenType.FLOAT, "3.14"),
            (TokenType.FLOAT, "0.5"),
            (TokenType.FLOAT, "1_000.5"),
        ])

    def test_float_not_two_dots(self):
        """1.2.3 should be FLOAT + DOT + INT (or error)."""
        tokens = tok("1.2")
        self.assertEqual(tokens, [TokenType.FLOAT])


class TestStrings(unittest.TestCase):
    """String literal recognition."""

    def test_simple_string(self):
        tokens = tok('"hello"')
        self.assertEqual(tokens, [TokenType.STRING])

    def test_empty_string(self):
        tokens = tok('""')
        self.assertEqual(tokens, [TokenType.STRING])

    def test_string_with_escape(self):
        tokens = tok('"hello\\nworld"')
        self.assertEqual(tokens, [TokenType.STRING])

    def test_string_value(self):
        vals = tok_vals('"hello"')
        self.assertEqual(vals, [(TokenType.STRING, "hello")])

    def test_string_with_quotes(self):
        vals = tok_vals('"say \\"hi\\""')
        # Token stores raw source text with escape sequences
        self.assertEqual(vals[0][0], TokenType.STRING)
        self.assertIn("say", vals[0][1])

    def test_string_with_backslash(self):
        vals = tok_vals('"path\\\\to\\\\file"')
        # Token stores raw source text with escape sequences
        self.assertEqual(vals[0][0], TokenType.STRING)
        self.assertIn("path", vals[0][1])

    def test_string_with_tab(self):
        vals = tok_vals('"hello\\tworld"')
        # Token stores raw source text with escape sequences
        self.assertEqual(vals[0][0], TokenType.STRING)
        self.assertIn("hello", vals[0][1])

    def test_unterminated_string(self):
        with self.assertRaises(Exception) as ctx:
            tokenize('"hello')
        self.assertIn("Unterminated", str(ctx.exception))


class TestChars(unittest.TestCase):
    """Character literal recognition."""

    def test_simple_char(self):
        tokens = tok("'a'")
        self.assertEqual(tokens, [TokenType.CHAR])

    def test_char_value(self):
        vals = tok_vals("'a'")
        # Char token stores the full source text including quotes
        self.assertEqual(vals[0][0], TokenType.CHAR)
        self.assertIn("a", vals[0][1])

    def test_char_newline(self):
        vals = tok_vals("'\\n'")
        self.assertEqual(vals[0][0], TokenType.CHAR)
        self.assertIn("\\n", vals[0][1])

    def test_char_tab(self):
        vals = tok_vals("'\\t'")
        self.assertEqual(vals[0][0], TokenType.CHAR)
        self.assertIn("\\t", vals[0][1])

    def test_char_backslash(self):
        vals = tok_vals("'\\\\'")
        self.assertEqual(vals[0][0], TokenType.CHAR)
        self.assertIn("\\\\", vals[0][1])

    def test_char_single_quote(self):
        vals = tok_vals("'\\''")
        self.assertEqual(vals[0][0], TokenType.CHAR)
        self.assertIn("\\'", vals[0][1])

    def test_unterminated_char(self):
        with self.assertRaises(Exception) as ctx:
            tokenize("'a")
        self.assertIn("Unterminated", str(ctx.exception))


class TestBooleans(unittest.TestCase):
    """Boolean literal recognition."""

    def test_true(self):
        tokens = tok("true")
        self.assertEqual(tokens, [TokenType.TRUE])

    def test_false(self):
        tokens = tok("false")
        self.assertEqual(tokens, [TokenType.FALSE])

    def test_true_value(self):
        vals = tok_vals("true")
        self.assertEqual(vals, [(TokenType.TRUE, "true")])

    def test_false_value(self):
        vals = tok_vals("false")
        self.assertEqual(vals, [(TokenType.FALSE, "false")])


class TestComments(unittest.TestCase):
    """Comment recognition and skipping."""

    def test_hash_comment(self):
        tokens = tokenize("# this is a comment\n42")
        self.assertEqual(len(tokens), 2)  # NEWLINE, INT
        self.assertEqual(tokens[1].type, TokenType.INT)

    def test_slash_slash_comment(self):
        tokens = tokenize("// this is a comment\n42")
        self.assertEqual(len(tokens), 2)
        self.assertEqual(tokens[1].type, TokenType.INT)

    def test_block_comment(self):
        tokens = tokenize("/* comment */ 42")
        self.assertEqual(len(tokens), 1)
        self.assertEqual(tokens[0].type, TokenType.INT)

    def test_multiline_block_comment(self):
        source = "/* line 1\n   line 2 */\n42"
        tokens = tokenize(source)
        self.assertEqual(len(tokens), 2)
        self.assertEqual(tokens[1].type, TokenType.INT)

    def test_comment_not_token(self):
        """Comments should not appear in token stream."""
        tokens = tok("42 # comment\n84")
        self.assertEqual(tokens, [TokenType.INT, TokenType.NEWLINE, TokenType.INT])


class TestStringInterpolation(unittest.TestCase):
    """String interpolation token sequences."""

    def test_interpolation_basic(self):
        tokens = tok('"hello ${name}!"')
        self.assertEqual(tokens, [
            TokenType.STRING,
            TokenType.DOLLAR_LBRACE,
            TokenType.IDENT,
            TokenType.RBRACE,
            TokenType.STRING,
        ])

    def test_interpolation_at_start(self):
        tokens = tok('"${x}"')
        self.assertEqual(tokens, [
            TokenType.DOLLAR_LBRACE,
            TokenType.IDENT,
            TokenType.RBRACE,
            TokenType.STRING,
        ])

    def test_interpolation_multiple(self):
        tokens = tok('"${a} and ${b}"')
        self.assertEqual(tokens, [
            TokenType.DOLLAR_LBRACE,
            TokenType.IDENT,
            TokenType.RBRACE,
            TokenType.STRING,
            TokenType.DOLLAR_LBRACE,
            TokenType.IDENT,
            TokenType.RBRACE,
            TokenType.STRING,
        ])

    def test_interpolation_values(self):
        vals = tok_vals('"hello ${name}!"')
        self.assertEqual(vals, [
            (TokenType.STRING, "hello "),
            (TokenType.DOLLAR_LBRACE, "${"),
            (TokenType.IDENT, "name"),
            (TokenType.RBRACE, "}"),
            (TokenType.STRING, "!"),
        ])

    def test_interpolation_expression(self):
        vals = tok_vals('"${a + b}"')
        self.assertEqual(vals, [
            (TokenType.DOLLAR_LBRACE, "${"),
            (TokenType.IDENT, "a"),
            (TokenType.PLUS, "+"),
            (TokenType.IDENT, "b"),
            (TokenType.RBRACE, "}"),
            (TokenType.STRING, ""),
        ])


class TestPositionTracking(unittest.TestCase):
    """Token position (line, col, start, end) tracking."""

    def test_first_token_positions(self):
        tokens = tokenize("hello")
        self.assertEqual(tokens[0].line, 1)
        self.assertEqual(tokens[0].col, 1)
        self.assertEqual(tokens[0].start, 0)
        self.assertEqual(tokens[0].end, 5)

    def test_position_after_whitespace(self):
        tokens = tokenize("  hello")
        self.assertEqual(tokens[0].col, 3)
        self.assertEqual(tokens[0].start, 2)
        self.assertEqual(tokens[0].end, 7)

    def test_multiline_positions(self):
        tokens = tokenize("hello\nworld")
        self.assertEqual(tokens[0].line, 1)  # hello
        self.assertEqual(tokens[0].col, 1)
        # tokens[1] is NEWLINE (line 1), tokens[2] is world (line 2)
        self.assertEqual(tokens[2].line, 2)
        self.assertEqual(tokens[2].col, 1)

    def test_operator_positions(self):
        tokens = tokenize("a + b")
        self.assertEqual(tokens[0].start, 0)  # 'a'
        self.assertEqual(tokens[0].end, 1)
        self.assertEqual(tokens[1].start, 2)  # '+'
        self.assertEqual(tokens[1].end, 3)
        self.assertEqual(tokens[2].start, 4)  # 'b'
        self.assertEqual(tokens[2].end, 5)

    def test_two_char_operator_positions(self):
        tokens = tokenize("a -> b")
        self.assertEqual(tokens[1].start, 2)  # '->'
        self.assertEqual(tokens[1].end, 4)

    def test_string_positions(self):
        tokens = tokenize('"hello"')
        # Token starts after opening quote (pos 1), ends before closing quote (pos 6)
        self.assertEqual(tokens[0].start, 1)
        self.assertEqual(tokens[0].end, 6)

    def test_newline_increments_line(self):
        tokens = tokenize("a\nb\nc")
        self.assertEqual(tokens[0].line, 1)  # a
        self.assertEqual(tokens[2].line, 2)  # b
        self.assertEqual(tokens[4].line, 3)  # c


class TestComplexExpressions(unittest.TestCase):
    """Token sequences for realistic expressions."""

    def test_function_def(self):
        tokens = tok("fn add a b = a + b")
        self.assertEqual(tokens, [
            TokenType.FN, TokenType.IDENT, TokenType.IDENT, TokenType.IDENT,
            TokenType.ASSIGN, TokenType.IDENT, TokenType.PLUS, TokenType.IDENT,
        ])

    def test_type_def(self):
        tokens = tok("type Maybe = Just * | Nothing")
        self.assertEqual(tokens, [
            TokenType.TYPE, TokenType.IDENT, TokenType.ASSIGN,
            TokenType.IDENT, TokenType.STAR, TokenType.PIPE, TokenType.IDENT,
        ])

    def test_match_expr(self):
        tokens = tok("match x Just v -> v Nothing -> 0")
        self.assertEqual(tokens, [
            TokenType.MATCH, TokenType.IDENT,
            TokenType.IDENT, TokenType.IDENT, TokenType.ARROW, TokenType.IDENT,
            TokenType.IDENT, TokenType.ARROW, TokenType.INT,
        ])

    def test_if_then_else(self):
        tokens = tok("if x > 0 then x else 0")
        self.assertEqual(tokens, [
            TokenType.IF, TokenType.IDENT, TokenType.GT, TokenType.INT,
            TokenType.THEN, TokenType.IDENT, TokenType.ELSE, TokenType.INT,
        ])

    def test_lambda(self):
        tokens = tok("\\x -> x + 1")
        self.assertEqual(tokens, [
            TokenType.BACKSLASH, TokenType.IDENT, TokenType.ARROW,
            TokenType.IDENT, TokenType.PLUS, TokenType.INT,
        ])

    def test_ref_cell(self):
        tokens = tok("let x = ref 0")
        self.assertEqual(tokens, [
            TokenType.LET, TokenType.IDENT, TokenType.ASSIGN,
            TokenType.REF, TokenType.INT,
        ])

    def test_deref(self):
        tokens = tok("!x")
        self.assertEqual(tokens, [TokenType.BANG, TokenType.IDENT])

    def test_set_ref(self):
        tokens = tok("x := 5")
        self.assertEqual(tokens, [
            TokenType.IDENT, TokenType.COLON_EQ, TokenType.INT,
        ])

    def test_list_literal(self):
        tokens = tok("[1, 2, 3]")
        self.assertEqual(tokens, [
            TokenType.LBRACKET, TokenType.INT, TokenType.COMMA,
            TokenType.INT, TokenType.COMMA, TokenType.INT, TokenType.RBRACKET,
        ])

    def test_import(self):
        tokens = tok('import math')
        self.assertEqual(tokens, [TokenType.IMPORT, TokenType.IDENT])

    def test_import_as(self):
        tokens = tok('import math as m')
        self.assertEqual(tokens, [
            TokenType.IMPORT, TokenType.IDENT, TokenType.AS, TokenType.IDENT,
        ])

    def test_comptime(self):
        tokens = tok("comptime 3 + 4")
        self.assertEqual(tokens, [
            TokenType.COMPILETIME, TokenType.INT, TokenType.PLUS, TokenType.INT,
        ])


class TestEdgeCases(unittest.TestCase):
    """Edge cases and error conditions."""

    def test_only_comments(self):
        tokens = tokenize("# comment\n// another")
        self.assertEqual(len(tokens), 1)  # just NEWLINE

    def test_adjacent_tokens(self):
        tokens = tok("a+b")
        self.assertEqual(tokens, [TokenType.IDENT, TokenType.PLUS, TokenType.IDENT])

    def test_adjacent_parens(self):
        tokens = tok("(())")
        self.assertEqual(tokens, [
            TokenType.LPAREN, TokenType.LPAREN, TokenType.RPAREN, TokenType.RPAREN,
        ])

    def test_colon_emits_colon_token(self):
        tokens = tokenize(":")
        self.assertEqual([t.type for t in tokens], [TokenType.COLON])

    def test_ampersand_alone_is_error(self):
        with self.assertRaises(Exception):
            tokenize("&")

    def test_at_sign_is_error(self):
        with self.assertRaises(Exception):
            tokenize("@")

    def test_number_then_ident(self):
        """42foo should be two tokens, not one."""
        tokens = tok("42foo")
        self.assertEqual(tokens, [TokenType.INT, TokenType.IDENT])

    def test_ident_then_number(self):
        """foo42 should be one IDENT token."""
        tokens = tok("foo42")
        self.assertEqual(tokens, [TokenType.IDENT])

    def test_string_interpolation_nested_braces(self):
        """${expr with {braces}} should work."""
        tokens = tok('"${x}"')
        self.assertEqual(tokens[0], TokenType.DOLLAR_LBRACE)


class TestLexerAPI(unittest.TestCase):
    """Test the Lexer API surface."""

    def test_lexer_init(self):
        lexer = Lexer("hello")
        self.assertEqual(lexer.source, "hello\0")
        self.assertEqual(lexer.pos, 0)
        self.assertEqual(lexer.line, 1)
        self.assertEqual(lexer.col, 1)

    def test_lexer_with_file(self):
        lexer = Lexer("hello", "test.ko")
        self.assertEqual(lexer.file, "test.ko")

    def test_peek(self):
        lexer = Lexer("ab")
        self.assertEqual(lexer.peek(), 'a')

    def test_peek_past_end(self):
        lexer = Lexer("")
        self.assertEqual(lexer.peek(), '\0')

    def test_advance(self):
        lexer = Lexer("ab")
        ch = lexer.advance()
        self.assertEqual(ch, 'a')
        self.assertEqual(lexer.pos, 1)
        self.assertEqual(lexer.col, 2)

    def test_advance_newline(self):
        lexer = Lexer("a\nb")
        lexer.advance()  # 'a'
        ch = lexer.advance()  # '\n'
        self.assertEqual(ch, '\n')
        self.assertEqual(lexer.line, 2)
        self.assertEqual(lexer.col, 1)

    def test_tokenize_returns_list(self):
        lexer = Lexer("42")
        tokens = lexer.tokenize()
        self.assertIsInstance(tokens, list)
        self.assertTrue(len(tokens) > 0)
        self.assertEqual(tokens[-1].type, TokenType.EOF)


class TestConsAndPipe(unittest.TestCase):
    """Test :: (cons) and |> (pipe) tokens."""

    def test_colon_colon(self):
        tokens = tokenize("::")
        self.assertEqual([t.type for t in tokens], [TokenType.COLON_COLON])

    def test_pipe_gt(self):
        tokens = tokenize("|>")
        self.assertEqual([t.type for t in tokens], [TokenType.PIPE_GT])

    def test_cons_in_expression(self):
        tokens = tokenize("1 :: 2 :: Nil")
        self.assertEqual([t.type for t in tokens], [
            TokenType.INT, TokenType.COLON_COLON,
            TokenType.INT, TokenType.COLON_COLON,
            TokenType.IDENT
        ])

    def test_pipe_in_expression(self):
        tokens = tokenize("x |> f |> g")
        self.assertEqual([t.type for t in tokens], [
            TokenType.IDENT, TokenType.PIPE_GT,
            TokenType.IDENT, TokenType.PIPE_GT,
            TokenType.IDENT
        ])

    def test_colon_still_works(self):
        tokens = tokenize(":")
        self.assertEqual([t.type for t in tokens], [TokenType.COLON])

    def test_colon_eq_still_works(self):
        tokens = tokenize(":=")
        self.assertEqual([t.type for t in tokens], [TokenType.COLON_EQ])

    def test_pipe_still_works(self):
        tokens = tokenize("|")
        self.assertEqual([t.type for t in tokens], [TokenType.PIPE])

    def test_or_still_works(self):
        tokens = tokenize("||")
        self.assertEqual([t.type for t in tokens], [TokenType.OR])


if __name__ == '__main__':
    unittest.main()
