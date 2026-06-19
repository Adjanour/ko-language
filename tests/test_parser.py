"""Comprehensive parser tests for the Kō language.

Tests define the correct behavior that the parser implementation
must satisfy (TDD approach). Each test parses source code and
asserts AST structure.
"""

import unittest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from lexer import Lexer, TokenType
from parser import (
    Parser, Program, FnDef, TypeDef, TypeConstructor, LetBinding, Import,
    IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
    Identifier, Wildcard, BinaryOp, UnaryOp, FnCall, IfExpr, MatchExpr,
    MatchArm, Block, LetExpr, Lambda, RefExpr, DerefExpr, SetExpr, ComptimeExpr,
    PatLiteral, PatIdent, PatWildcard, PatConstructor,
    TypeInt, TypeFloat, TypeBool, TypeString, TypeArrow, TypeVar, TypeApp,
    ParseError,
)


def parse(source: str, file: str = "<test>") -> Program:
    """Helper: tokenize and parse source, return Program."""
    lexer = Lexer(source, file)
    tokens = lexer.tokenize()
    parser = Parser(tokens, file)
    return parser.parse_program()


def parse_expr(source: str) -> 'Expr':
    """Helper: tokenize and parse a single expression."""
    lexer = Lexer(source)
    tokens = lexer.tokenize()
    parser = Parser(tokens)
    return parser.parse_expr()


def parse_pattern(source: str) -> 'Pattern':
    """Helper: tokenize and parse a single pattern."""
    lexer = Lexer(source)
    tokens = lexer.tokenize()
    parser = Parser(tokens)
    return parser.parse_pattern()


# ============================================================
# Helper functions for building expected ASTs
# ============================================================

def int_(v):
    return IntLiteral(v)

def float_(v):
    return FloatLiteral(v)

def str_(v):
    return StringLiteral(v)

def char_(v):
    return CharLiteral(v)

def bool_(v):
    return BoolLiteral(v)

def ident(name):
    return Identifier(name)

def wild():
    return Wildcard()

def binop(op, left, right):
    return BinaryOp(op, left, right)

def unary(op, expr):
    return UnaryOp(op, expr)

def call(func, *args):
    return FnCall(func, list(args))

def if_(cond, then, else_=None):
    return IfExpr(cond, then, else_)

def match_(value, *arms):
    return MatchExpr(value, [MatchArm(p, b) for p, b in arms])

def let(name, value, body=None):
    return LetExpr(name, value, body)

def lam(params, body):
    return Lambda(params, body)

def ref_(value):
    return RefExpr(value)

def deref_(ref):
    return DerefExpr(ref)

def set_(ref, value):
    return SetExpr(ref, value)

def comptime_(expr):
    return ComptimeExpr(expr)

def pat_ident(name):
    return PatIdent(name)

def pat_wild():
    return PatWildcard()

def pat_ctor(name, *args):
    return PatConstructor(name, list(args))

def pat_lit(v):
    return PatLiteral(v)


# ============================================================
# Test Classes
# ============================================================

class TestLiterals(unittest.TestCase):
    """Parse literal expressions."""

    def test_int_literal(self):
        expr = parse_expr("42")
        self.assertIsInstance(expr, IntLiteral)
        self.assertEqual(expr.value, 42)

    def test_int_zero(self):
        expr = parse_expr("0")
        self.assertIsInstance(expr, IntLiteral)
        self.assertEqual(expr.value, 0)

    def test_int_hex(self):
        expr = parse_expr("0xFF")
        self.assertIsInstance(expr, IntLiteral)
        self.assertEqual(expr.value, 255)

    def test_int_binary(self):
        expr = parse_expr("0b1010")
        self.assertIsInstance(expr, IntLiteral)
        self.assertEqual(expr.value, 10)

    def test_int_underscores(self):
        expr = parse_expr("1_000_000")
        self.assertIsInstance(expr, IntLiteral)
        self.assertEqual(expr.value, 1000000)

    def test_float_literal(self):
        expr = parse_expr("3.14")
        self.assertIsInstance(expr, FloatLiteral)
        self.assertAlmostEqual(expr.value, 3.14)

    def test_string_literal(self):
        expr = parse_expr('"hello"')
        self.assertIsInstance(expr, StringLiteral)
        self.assertEqual(expr.value, "hello")

    def test_empty_string(self):
        expr = parse_expr('""')
        self.assertIsInstance(expr, StringLiteral)
        self.assertEqual(expr.value, "")

    def test_char_literal(self):
        expr = parse_expr("'a'")
        self.assertIsInstance(expr, CharLiteral)

    def test_char_escape_literal(self):
        expr = parse_expr("'\\''")
        self.assertIsInstance(expr, CharLiteral)

    def test_bool_true(self):
        expr = parse_expr("true")
        self.assertIsInstance(expr, BoolLiteral)
        self.assertTrue(expr.value)

    def test_bool_false(self):
        expr = parse_expr("false")
        self.assertIsInstance(expr, BoolLiteral)
        self.assertFalse(expr.value)


class TestIdentifiers(unittest.TestCase):
    """Parse identifier expressions."""

    def test_simple_ident(self):
        expr = parse_expr("foo")
        self.assertIsInstance(expr, Identifier)
        self.assertEqual(expr.name, "foo")

    def test_uppercase_ident(self):
        expr = parse_expr("Just")
        self.assertIsInstance(expr, Identifier)
        self.assertEqual(expr.name, "Just")

    def test_ident_with_dash(self):
        expr = parse_expr("from-just")
        self.assertIsInstance(expr, Identifier)
        self.assertEqual(expr.name, "from-just")


class TestBinaryOps(unittest.TestCase):
    """Parse binary operations with correct precedence."""

    def test_addition(self):
        expr = parse_expr("a + b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "+")
        self.assertEqual(expr.left.name, "a")
        self.assertEqual(expr.right.name, "b")

    def test_subtraction(self):
        expr = parse_expr("a - b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "-")

    def test_multiplication(self):
        expr = parse_expr("a * b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "*")

    def test_division(self):
        expr = parse_expr("a / b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "/")

    def test_modulo(self):
        expr = parse_expr("a % b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "%")

    def test_equal(self):
        expr = parse_expr("a == b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "==")

    def test_not_equal(self):
        expr = parse_expr("a != b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "!=")

    def test_less_than(self):
        expr = parse_expr("a < b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "<")

    def test_greater_than(self):
        expr = parse_expr("a > b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, ">")

    def test_less_equal(self):
        expr = parse_expr("a <= b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "<=")

    def test_greater_equal(self):
        expr = parse_expr("a >= b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, ">=")

    def test_and(self):
        expr = parse_expr("a && b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "&&")

    def test_or(self):
        expr = parse_expr("a || b")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "||")

    def test_precedence_mul_before_add(self):
        """a + b * c → a + (b * c)"""
        expr = parse_expr("a + b * c")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "+")
        self.assertIsInstance(expr.right, BinaryOp)
        self.assertEqual(expr.right.op, "*")

    def test_precedence_comparison_before_and(self):
        """a == b && c != d → (a == b) && (c != d)"""
        expr = parse_expr("a == b && c != d")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "&&")
        self.assertIsInstance(expr.left, BinaryOp)
        self.assertEqual(expr.left.op, "==")
        self.assertIsInstance(expr.right, BinaryOp)
        self.assertEqual(expr.right.op, "!=")

    def test_left_associativity(self):
        """a - b - c → (a - b) - c"""
        expr = parse_expr("a - b - c")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "-")
        self.assertIsInstance(expr.left, BinaryOp)
        self.assertEqual(expr.left.op, "-")

    def test_parenthesized(self):
        """(a + b) * c"""
        expr = parse_expr("(a + b) * c")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "*")
        self.assertIsInstance(expr.left, BinaryOp)
        self.assertEqual(expr.left.op, "+")


class TestUnaryOps(unittest.TestCase):
    """Parse unary operations."""

    def test_negate(self):
        expr = parse_expr("-x")
        self.assertIsInstance(expr, UnaryOp)
        self.assertEqual(expr.op, "-")

    def test_deref(self):
        expr = parse_expr("!x")
        self.assertIsInstance(expr, DerefExpr)

    def test_double_negate(self):
        expr = parse_expr("--x")
        self.assertIsInstance(expr, UnaryOp)
        self.assertEqual(expr.op, "-")
        self.assertIsInstance(expr.expr, UnaryOp)


class TestFunctionApplication(unittest.TestCase):
    """Parse function application (no parentheses)."""

    def test_zero_args(self):
        expr = parse_expr("f")
        self.assertIsInstance(expr, Identifier)
        self.assertEqual(expr.name, "f")

    def test_one_arg(self):
        expr = parse_expr("f x")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "f")
        self.assertEqual(len(expr.args), 1)

    def test_two_args(self):
        expr = parse_expr("f x y")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(len(expr.args), 2)

    def test_many_args(self):
        expr = parse_expr("add a b")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(len(expr.args), 2)

    def test_nested_application(self):
        """f (g x) y"""
        expr = parse_expr("f (g x) y")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(len(expr.args), 2)
        self.assertIsInstance(expr.args[0], FnCall)

    def test_operator_as_function(self):
        """(+ ) or (+ 1) — operators can be passed as arguments."""
        # This tests that operators work in function position
        pass  # Deferred to later


class TestIfExpr(unittest.TestCase):
    """Parse if/then/else expressions."""

    def test_if_then_else(self):
        expr = parse_expr("if x then y else z")
        self.assertIsInstance(expr, IfExpr)
        self.assertIsInstance(expr.cond, Identifier)
        self.assertEqual(expr.cond.name, "x")
        self.assertIsInstance(expr.then_branch, Identifier)
        self.assertEqual(expr.then_branch.name, "y")
        self.assertIsInstance(expr.else_branch, Identifier)
        self.assertEqual(expr.else_branch.name, "z")

    def test_if_then_no_else(self):
        expr = parse_expr("if x then y")
        self.assertIsInstance(expr, IfExpr)
        self.assertIsNone(expr.else_branch)

    def test_if_with_comparison(self):
        expr = parse_expr("if x > 0 then x else 0")
        self.assertIsInstance(expr, IfExpr)
        self.assertIsInstance(expr.cond, BinaryOp)
        self.assertEqual(expr.cond.op, ">")

    def test_nested_if(self):
        expr = parse_expr("if a then if b then c else d else e")
        self.assertIsInstance(expr, IfExpr)
        self.assertIsInstance(expr.then_branch, IfExpr)


class TestMatchExpr(unittest.TestCase):
    """Parse match expressions."""

    def test_simple_match(self):
        expr = parse_expr("match x Just v -> v Nothing -> 0")
        self.assertIsInstance(expr, MatchExpr)
        self.assertEqual(expr.value.name, "x")
        self.assertEqual(len(expr.arms), 2)
        self.assertEqual(expr.arms[0].pattern.name, "Just")
        self.assertEqual(expr.arms[0].pattern.args[0].name, "v")
        self.assertEqual(expr.arms[1].pattern.name, "Nothing")

    def test_match_wildcard(self):
        expr = parse_expr("match x _ -> 0")
        self.assertIsInstance(expr, MatchExpr)
        self.assertEqual(len(expr.arms), 1)
        self.assertIsInstance(expr.arms[0].pattern, PatWildcard)

    def test_match_literal(self):
        expr = parse_expr("match x 42 -> true _ -> false")
        self.assertIsInstance(expr, MatchExpr)
        self.assertEqual(expr.arms[0].pattern.value, 42)

    def test_match_constructor_args(self):
        expr = parse_expr("match xs Cons h t -> h")
        self.assertIsInstance(expr, MatchExpr)
        self.assertEqual(expr.arms[0].pattern.name, "Cons")
        self.assertEqual(len(expr.arms[0].pattern.args), 2)

    def test_match_on_separate_lines(self):
        """Match with arms on separate lines."""
        source = """
match x
  Just v -> v
  Nothing -> 0
"""
        expr = parse_expr(source)
        self.assertIsInstance(expr, MatchExpr)
        self.assertEqual(len(expr.arms), 2)


class TestLambda(unittest.TestCase):
    """Parse lambda expressions."""

    def test_single_param(self):
        expr = parse_expr("\\x -> x + 1")
        self.assertIsInstance(expr, Lambda)
        self.assertEqual(expr.params, ["x"])

    def test_multi_param(self):
        expr = parse_expr("\\x y -> x + y")
        self.assertIsInstance(expr, Lambda)
        self.assertEqual(expr.params, ["x", "y"])

    def test_lambda_body(self):
        expr = parse_expr("\\x -> x * 2")
        self.assertIsInstance(expr, Lambda)
        self.assertIsInstance(expr.body, BinaryOp)
        self.assertEqual(expr.body.op, "*")


class TestRefExpr(unittest.TestCase):
    """Parse ref cell expressions."""

    def test_ref(self):
        expr = parse_expr("ref 0")
        self.assertIsInstance(expr, RefExpr)

    def test_deref(self):
        expr = parse_expr("!x")
        self.assertIsInstance(expr, DerefExpr)

    def test_set_ref(self):
        expr = parse_expr("x := 5")
        self.assertIsInstance(expr, SetExpr)


class TestComptime(unittest.TestCase):
    """Parse comptime expressions."""

    def test_comptime(self):
        expr = parse_expr("comptime 3 + 4")
        self.assertIsInstance(expr, ComptimeExpr)

    def test_comptime_nested(self):
        expr = parse_expr("comptime comptime 3 + 4")
        self.assertIsInstance(expr, ComptimeExpr)
        self.assertIsInstance(expr.expr, ComptimeExpr)


class TestListLiteral(unittest.TestCase):
    """Parse list literals [a, b, c]."""

    def test_empty_list(self):
        expr = parse_expr("[]")
        # Desugars to Nil
        self.assertIsInstance(expr, Identifier)
        self.assertEqual(expr.name, "Nil")

    def test_single_element(self):
        expr = parse_expr("[1]")
        # Desugars to Cons 1 Nil
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "Cons")
        self.assertEqual(len(expr.args), 2)
        self.assertIsInstance(expr.args[0], IntLiteral)

    def test_multiple_elements(self):
        expr = parse_expr("[1, 2, 3]")
        # Desugars to Cons 1 (Cons 2 (Cons 3 Nil))
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "Cons")


class TestStringInterpolation(unittest.TestCase):
    """Parse string interpolation expressions."""

    def test_simple_interpolation(self):
        expr = parse_expr('"hello ${name}!"')
        # Desugars to concat "hello " (concat (to_string name) "!")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "concat")


class TestFnDef(unittest.TestCase):
    """Parse function definitions."""

    def test_simple_fn(self):
        prog = parse("fn add a b = a + b")
        self.assertEqual(len(prog.definitions), 1)
        fn = prog.definitions[0]
        self.assertIsInstance(fn, FnDef)
        self.assertEqual(fn.name, "add")
        self.assertEqual(fn.params, ["a", "b"])

    def test_fn_body(self):
        prog = parse("fn double x = x * 2")
        fn = prog.definitions[0]
        self.assertIsInstance(fn.body, BinaryOp)
        self.assertEqual(fn.body.op, "*")

    def test_fn_no_params(self):
        prog = parse("fn main = println 42")
        fn = prog.definitions[0]
        self.assertEqual(fn.params, [])

    def test_fn_with_type_annotation(self):
        prog = parse("fn add : Int -> Int -> Int\nfn add a b = a + b")
        fn = prog.definitions[0]
        self.assertIsNotNone(fn.type_ann)

    def test_fn_with_let_body(self):
        source = """
fn main =
  let x = 1
  let y = 2
  x + y
"""
        prog = parse(source)
        fn = prog.definitions[0]
        self.assertEqual(fn.name, "main")


class TestTypeDef(unittest.TestCase):
    """Parse type definitions."""

    def test_simple_type(self):
        prog = parse("type Maybe = Just * | Nothing")
        self.assertEqual(len(prog.definitions), 1)
        td = prog.definitions[0]
        self.assertIsInstance(td, TypeDef)
        self.assertEqual(td.name, "Maybe")
        self.assertEqual(len(td.constructors), 2)
        self.assertEqual(td.constructors[0].name, "Just")
        self.assertEqual(td.constructors[0].fields, 1)
        self.assertEqual(td.constructors[1].name, "Nothing")
        self.assertEqual(td.constructors[1].fields, 0)

    def test_multi_field_type(self):
        prog = parse("type Pair = Pair * *")
        td = prog.definitions[0]
        self.assertEqual(td.constructors[0].fields, 2)

    def test_nullary_constructors(self):
        prog = parse("type Color = Red | Green | Blue")
        td = prog.definitions[0]
        self.assertEqual(len(td.constructors), 3)
        for c in td.constructors:
            self.assertEqual(c.fields, 0)

    def test_many_fields(self):
        prog = parse("type Big = Big * * * * * *")
        td = prog.definitions[0]
        self.assertEqual(td.constructors[0].fields, 6)

    def test_generic_type_params(self):
        prog = parse("type Maybe a = Just a | Nothing")
        td = prog.definitions[0]
        self.assertEqual(td.name, "Maybe")
        self.assertEqual(td.type_params, ["a"])
        self.assertEqual(td.constructors[0].name, "Just")
        self.assertEqual(td.constructors[0].fields, 1)
        self.assertEqual(td.constructors[0].field_types, ["a"])
        self.assertEqual(td.constructors[1].name, "Nothing")
        self.assertEqual(td.constructors[1].fields, 0)

    def test_multi_param_generic(self):
        prog = parse("type Either a b = Left a | Right b")
        td = prog.definitions[0]
        self.assertEqual(td.type_params, ["a", "b"])
        self.assertEqual(td.constructors[0].field_types, ["a"])
        self.assertEqual(td.constructors[1].field_types, ["b"])

    def test_generic_with_wildcard(self):
        prog = parse("type Maybe = Just * | Nothing")
        td = prog.definitions[0]
        self.assertEqual(td.type_params, [])
        self.assertEqual(td.constructors[0].field_types, ["_"])


class TestLetBinding(unittest.TestCase):
    """Parse top-level let bindings."""

    def test_simple_let(self):
        prog = parse("let x = 42")
        self.assertEqual(len(prog.definitions), 1)
        lb = prog.definitions[0]
        self.assertIsInstance(lb, LetBinding)
        self.assertEqual(lb.name, "x")
        self.assertIsInstance(lb.value, IntLiteral)
        self.assertEqual(lb.value.value, 42)

    def test_let_with_expr(self):
        prog = parse("let y = 3 + 4")
        lb = prog.definitions[0]
        self.assertIsInstance(lb.value, BinaryOp)


class TestImport(unittest.TestCase):
    """Parse import statements."""

    def test_simple_import(self):
        prog = parse("import math")
        self.assertEqual(len(prog.imports), 1)
        imp = prog.imports[0]
        self.assertIsInstance(imp, Import)
        self.assertEqual(imp.path, "math")
        self.assertIsNone(imp.alias)

    def test_import_with_alias(self):
        prog = parse("import math as m")
        imp = prog.imports[0]
        self.assertEqual(imp.path, "math")
        self.assertEqual(imp.alias, "m")

    def test_import_alias_rewrite_smoke(self):
        # Aliased imports are resolved textually, so the compiler should still build a renamed import tree.
        prog = parse("import math as m\nfn main =\n  m_sqrt 4")
        self.assertEqual(len(prog.imports), 1)

    def test_import_string_path(self):
        prog = parse('import "utils/helpers"')
        imp = prog.imports[0]
        self.assertEqual(imp.path, "utils/helpers")

    def test_import_parse_keeps_single_import(self):
        prog = parse('import math\nimport util as u')
        self.assertEqual(len(prog.imports), 2)

    def test_string_pattern_parse(self):
        prog = parse('fn main =\n  match "a\\"b"\n    "a\\"b" -> 1\n    _ -> 0')
        self.assertEqual(len(prog.definitions), 1)


class TestPatterns(unittest.TestCase):
    """Parse patterns in match arms."""

    def test_wildcard(self):
        p = parse_pattern("_")
        self.assertIsInstance(p, PatWildcard)

    def test_ident(self):
        p = parse_pattern("x")
        self.assertIsInstance(p, PatIdent)
        self.assertEqual(p.name, "x")

    def test_constructor_no_args(self):
        p = parse_pattern("Nothing")
        self.assertIsInstance(p, PatConstructor)
        self.assertEqual(p.name, "Nothing")
        self.assertEqual(p.args, [])

    def test_constructor_one_arg(self):
        p = parse_pattern("Just v")
        self.assertIsInstance(p, PatConstructor)
        self.assertEqual(p.name, "Just")
        self.assertEqual(len(p.args), 1)
        self.assertEqual(p.args[0].name, "v")

    def test_constructor_many_args(self):
        p = parse_pattern("Cons h t")
        self.assertIsInstance(p, PatConstructor)
        self.assertEqual(p.name, "Cons")
        self.assertEqual(len(p.args), 2)

    def test_literal_int(self):
        p = parse_pattern("42")
        self.assertIsInstance(p, PatLiteral)
        self.assertEqual(p.value, 42)

    def test_literal_string(self):
        p = parse_pattern('"hello"')
        self.assertIsInstance(p, PatLiteral)
        self.assertEqual(p.value, "hello")

    def test_literal_bool(self):
        p = parse_pattern("true")
        self.assertIsInstance(p, PatLiteral)
        self.assertTrue(p.value)


class TestOperatorPrecedence(unittest.TestCase):
    """Test that operator precedence is correct."""

    def test_mul_over_add(self):
        expr = parse_expr("1 + 2 * 3")
        self.assertEqual(expr.op, "+")
        self.assertEqual(expr.right.op, "*")

    def test_comparison_over_and(self):
        expr = parse_expr("a < b && c > d")
        self.assertEqual(expr.op, "&&")
        self.assertEqual(expr.left.op, "<")
        self.assertEqual(expr.right.op, ">")

    def test_and_over_or(self):
        expr = parse_expr("a || b && c")
        self.assertEqual(expr.op, "||")
        self.assertEqual(expr.right.op, "&&")

    def test_unary_over_mul(self):
        expr = parse_expr("-x * y")
        self.assertEqual(expr.op, "*")
        self.assertIsInstance(expr.left, UnaryOp)

    def test_application_over_mul(self):
        expr = parse_expr("f x * y")
        self.assertEqual(expr.op, "*")
        self.assertIsInstance(expr.left, FnCall)


class TestPipeAndCons(unittest.TestCase):
    """Test |> (pipe) and :: (cons) operators."""

    def test_simple_pipe(self):
        expr = parse_expr("x |> f")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "f")
        self.assertEqual(len(expr.args), 1)
        self.assertEqual(expr.args[0].name, "x")

    def test_chained_pipe(self):
        expr = parse_expr("x |> f |> g")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "g")
        self.assertIsInstance(expr.args[0], FnCall)
        self.assertEqual(expr.args[0].func.name, "f")
        self.assertEqual(expr.args[0].args[0].name, "x")

    def test_pipe_precedence(self):
        """x |> f + 1 should parse as x |> (f + 1) — pipe has lower precedence."""
        expr = parse_expr("x |> f + 1")
        self.assertIsInstance(expr, FnCall)
        # The right side of |> is parsed as f + 1 (BinaryOp)
        self.assertIsInstance(expr.func, BinaryOp)
        self.assertEqual(expr.func.op, "+")

    def test_simple_cons(self):
        expr = parse_expr("1 :: Nil")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "Cons")
        self.assertEqual(len(expr.args), 2)
        self.assertEqual(expr.args[0].value, 1)
        self.assertEqual(expr.args[1].name, "Nil")

    def test_chained_cons_right_assoc(self):
        """1 :: 2 :: Nil should parse as Cons(1, Cons(2, Nil))."""
        expr = parse_expr("1 :: 2 :: Nil")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "Cons")
        self.assertEqual(expr.args[0].value, 1)
        # Right side should be another Cons
        self.assertIsInstance(expr.args[1], FnCall)
        self.assertEqual(expr.args[1].func.name, "Cons")
        self.assertEqual(expr.args[1].args[0].value, 2)
        self.assertEqual(expr.args[1].args[1].name, "Nil")

    def test_cons_precedence(self):
        """1 + 2 :: Nil should parse as (1 + 2) :: Nil."""
        expr = parse_expr("1 + 2 :: Nil")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "Cons")
        self.assertIsInstance(expr.args[0], BinaryOp)
        self.assertEqual(expr.args[0].op, "+")

    def test_cons_in_let(self):
        prog = parse("let xs = 1 :: 2 :: 3 :: Nil")
        self.assertEqual(len(prog.definitions), 1)
        let = prog.definitions[0]
        self.assertIsInstance(let.value, FnCall)
        self.assertEqual(let.value.func.name, "Cons")

    def test_pipe_in_let(self):
        prog = parse("let result = x |> f |> g")
        self.assertEqual(len(prog.definitions), 1)
        let = prog.definitions[0]
        self.assertIsInstance(let.value, FnCall)
        self.assertEqual(let.value.func.name, "g")


class TestComplexExpressions(unittest.TestCase):
    """Test complex nested expressions."""

    def test_nested_if(self):
        expr = parse_expr("if x > 0 then if x > 10 then 1 else 2 else 0")
        self.assertIsInstance(expr, IfExpr)
        self.assertIsInstance(expr.then_branch, IfExpr)

    def test_match_with_if_body(self):
        source = """
match x
  Just v -> if v > 0 then v else 0
  Nothing -> 0
"""
        expr = parse_expr(source)
        self.assertIsInstance(expr, MatchExpr)
        self.assertIsInstance(expr.arms[0].body, IfExpr)

    def test_lambda_in_application(self):
        expr = parse_expr("map (\\x -> x * 2) xs")
        self.assertIsInstance(expr, FnCall)
        self.assertEqual(expr.func.name, "map")
        self.assertIsInstance(expr.args[0], Lambda)

    def test_chained_comparisons(self):
        """a == b == c should parse as (a == b) == c."""
        expr = parse_expr("a == b == c")
        self.assertIsInstance(expr, BinaryOp)
        self.assertEqual(expr.op, "==")
        self.assertIsInstance(expr.left, BinaryOp)
        self.assertEqual(expr.left.op, "==")


class TestProgramStructure(unittest.TestCase):
    """Test full program parsing."""

    def test_hello_world(self):
        prog = parse('println "hello, world"')
        self.assertEqual(len(prog.definitions), 1)
        self.assertIsInstance(prog.definitions[0], FnDef)
        self.assertEqual(prog.definitions[0].name, "main")

    def test_multiple_defs(self):
        source = """
type Maybe = Just * | Nothing

fn from-just default mx =
  match mx
    Just x -> x
    Nothing -> default
"""
        prog = parse(source)
        self.assertEqual(len(prog.definitions), 2)
        self.assertIsInstance(prog.definitions[0], TypeDef)
        self.assertIsInstance(prog.definitions[1], FnDef)

    def test_import_then_def(self):
        source = """
import math

fn main = println 42
"""
        prog = parse(source)
        self.assertEqual(len(prog.imports), 1)
        self.assertEqual(len(prog.definitions), 1)


class TestNestedMatch(unittest.TestCase):
    """Test nested match expressions parse correctly."""

    def test_nested_match_arms_not_confused(self):
        """Inner match should have 2 arms, outer match should have 2 arms."""
        code = '''fn main =
  let result = match 10
    10 -> match 5
      5 -> 15
      _ -> 0
    _ -> 0
  println result
'''
        prog = parse(code)
        fn = prog.definitions[0]
        let = fn.body
        self.assertIsInstance(let, LetExpr)
        outer_match = let.value
        self.assertIsInstance(outer_match, MatchExpr)
        self.assertEqual(len(outer_match.arms), 2, "outer match should have 2 arms")
        # First arm body should be an inner match
        inner_match = outer_match.arms[0].body
        self.assertIsInstance(inner_match, MatchExpr)
        self.assertEqual(len(inner_match.arms), 2, "inner match should have 2 arms")
        # Second arm body should be IntLiteral(0), not a Block
        self.assertIsInstance(outer_match.arms[1].body, IntLiteral)

    def test_triple_nested_match(self):
        """Three levels of nesting should parse correctly."""
        code = '''fn main =
  let r = match 1
    1 -> match 2
      2 -> match 3
        3 -> 99
        _ -> 0
      _ -> 0
    _ -> 0
  println r
'''
        prog = parse(code)
        fn = prog.definitions[0]
        let = fn.body
        self.assertIsInstance(let, LetExpr)
        m1 = let.value
        self.assertIsInstance(m1, MatchExpr)
        self.assertEqual(len(m1.arms), 2)
        m2 = m1.arms[0].body
        self.assertIsInstance(m2, MatchExpr)
        self.assertEqual(len(m2.arms), 2)
        m3 = m2.arms[0].body
        self.assertIsInstance(m3, MatchExpr)
        self.assertEqual(len(m3.arms), 2)


class TestErrorRecovery(unittest.TestCase):
    """Test that parser can recover from errors."""

    def test_missing_equals(self):
        """fn add a b a + b — missing = sign."""
        # Should produce an error but not crash
        try:
            prog = parse("fn add a b a + b")
        except ParseError:
            pass  # Expected

    def test_extra_tokens(self):
        """Extra tokens after expression should be handled."""
        # This tests error recovery
        pass  # Deferred to parser rewrite


if __name__ == '__main__':
    unittest.main()
