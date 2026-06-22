"""Kō Parser — Recursive descent parser for the Kō language.

Design principles (from Go, Rust, Zig):
- One function per grammar rule (Go-style)
- Precedence climbing via layered functions
- match() / expect() / advance() helpers
- Error recovery with synchronization points
- Clean match arm parsing (no hackery)
"""

from dataclasses import dataclass, field
from typing import List, Optional, Union
from enum import Enum, auto
from lexer import Token, TokenType, LexerError
from errors import SourceLocation


def loc_from_token(token: Token, file: str = "<input>") -> SourceLocation:
    """Create a SourceLocation from a token."""
    return SourceLocation(file, token.line, token.col, token.start, token.end)


def loc_range(start: Token, end: Token, file: str = "<input>") -> SourceLocation:
    """Create a SourceLocation spanning from start to end token."""
    return SourceLocation(file, start.line, start.col, start.start, end.end)


# ============================================================
# AST Nodes
# ============================================================

@dataclass
class IntLiteral:
    value: int
    loc: Optional[SourceLocation] = None

@dataclass
class FloatLiteral:
    value: float
    loc: Optional[SourceLocation] = None

@dataclass
class StringLiteral:
    value: str
    loc: Optional[SourceLocation] = None

@dataclass
class CharLiteral:
    value: str
    loc: Optional[SourceLocation] = None

@dataclass
class BoolLiteral:
    value: bool
    loc: Optional[SourceLocation] = None

@dataclass
class Identifier:
    name: str
    loc: Optional[SourceLocation] = None

@dataclass
class Wildcard:
    loc: Optional[SourceLocation] = None

@dataclass
class BinaryOp:
    op: str
    left: 'Expr'
    right: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class UnaryOp:
    op: str
    expr: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class FnCall:
    func: 'Expr'
    args: List['Expr']
    named_args: List['NamedArg'] = None
    loc: Optional[SourceLocation] = None

@dataclass
class NamedArg:
    name: str
    value: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class FieldAccess:
    object: 'Expr'
    field: str
    loc: Optional[SourceLocation] = None

@dataclass
class IfExpr:
    cond: 'Expr'
    then_branch: 'Expr'
    else_branch: Optional['Expr']
    loc: Optional[SourceLocation] = None

@dataclass
class MatchArm:
    pattern: 'Pattern'
    body: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class MatchExpr:
    value: 'Expr'
    arms: List[MatchArm]
    loc: Optional[SourceLocation] = None

@dataclass
class Block:
    exprs: List['Expr']
    loc: Optional[SourceLocation] = None

@dataclass
class LetExpr:
    name: str
    value: 'Expr'
    body: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class Lambda:
    params: List[str]
    body: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class RefExpr:
    value: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class DerefExpr:
    ref: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class SetExpr:
    ref: 'Expr'
    value: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class ComptimeExpr:
    expr: 'Expr'
    loc: Optional[SourceLocation] = None

@dataclass
class TupleExpr:
    elements: List['Expr']
    loc: Optional[SourceLocation] = None

# Type expressions
@dataclass
class TypeInt:
    loc: Optional[SourceLocation] = None

@dataclass
class TypeFloat:
    loc: Optional[SourceLocation] = None

@dataclass
class TypeBool:
    loc: Optional[SourceLocation] = None

@dataclass
class TypeString:
    loc: Optional[SourceLocation] = None

@dataclass
class TypeChar:
    loc: Optional[SourceLocation] = None

@dataclass
class TypeUnit:
    loc: Optional[SourceLocation] = None

@dataclass
class TypeVar:
    name: str
    loc: Optional[SourceLocation] = None

@dataclass
class TypeArrow:
    from_type: 'TypeExpr'
    to_type: 'TypeExpr'
    loc: Optional[SourceLocation] = None

@dataclass
class TypeApp:
    name: str
    args: List['TypeExpr']
    loc: Optional[SourceLocation] = None

@dataclass
class TupleType:
    elements: List['TypeExpr']
    loc: Optional[SourceLocation] = None

TypeExpr = Union[TypeInt, TypeFloat, TypeBool, TypeString, TypeChar, TypeUnit, TypeVar, TypeArrow, TypeApp, TupleType]

@dataclass
class FnDef:
    name: str
    params: List[str]
    body: 'Expr'
    type_ann: Optional[TypeExpr] = None
    comptime: bool = False
    pub: bool = False
    named_params: List[str] = None
    loc: Optional[SourceLocation] = None

@dataclass
class LetBinding:
    name: str
    value: 'Expr'
    pub: bool = False
    loc: Optional[SourceLocation] = None

@dataclass
class TypeDef:
    name: str
    type_params: List[str]
    constructors: List['TypeConstructor']
    pub: bool = False
    loc: Optional[SourceLocation] = None

@dataclass
class TypeConstructor:
    name: str
    fields: int
    field_types: List = None  # List of type exprs (* = fresh var)
    loc: Optional[SourceLocation] = None

@dataclass
class ModuleDef:
    name: str
    definitions: List[Union['FnDef', 'LetBinding', 'TypeDef', 'ModuleDef']]
    pub: bool = False
    loc: Optional[SourceLocation] = None

@dataclass
class Program:
    imports: List['Import']
    definitions: List[Union[FnDef, LetBinding, TypeDef, ModuleDef]]
    package: Optional[str] = None  # package declaration

# Patterns

@dataclass
class PatLiteral:
    value: Union[int, float, str, bool]
    loc: Optional[SourceLocation] = None

@dataclass
class PatIdent:
    name: str
    loc: Optional[SourceLocation] = None

@dataclass
class PatWildcard:
    loc: Optional[SourceLocation] = None

@dataclass
class PatConstructor:
    name: str
    args: List['Pattern']
    loc: Optional[SourceLocation] = None

@dataclass
class PatTuple:
    elements: List['Pattern']
    loc: Optional[SourceLocation] = None

Pattern = Union[PatLiteral, PatIdent, PatWildcard, PatConstructor, PatTuple]
Expr = Union[IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
             Identifier, Wildcard, BinaryOp, UnaryOp, FnCall, FieldAccess, IfExpr, MatchExpr,
             Block, LetExpr, Lambda, RefExpr, DerefExpr, SetExpr, ComptimeExpr, TupleExpr]


@dataclass
class Import:
    path: str
    alias: Optional[str] = None
    selective: Optional[List[str]] = None  # for `import math.{sin, cos}`
    loc: Optional[SourceLocation] = None


class ParseError(Exception):
    def __init__(self, msg, token, notes=None):
        super().__init__(f"Parse error at {token.line}:{token.col}: {msg}")
        self.msg = msg
        self.token = token
        self.notes = notes or []


# ============================================================
# Parser
# ============================================================

class Parser:
    def __init__(self, tokens: List[Token], file: str = "<input>"):
        self.tokens = tokens
        self.pos = 0
        self.file = file
        self.errors: List[ParseError] = []

    # --- Token navigation helpers (Go-style) ---

    def peek(self) -> Token:
        return self.tokens[self.pos]

    def advance(self) -> Token:
        token = self.tokens[self.pos]
        self.pos += 1
        return token

    def check(self, ttype: TokenType) -> bool:
        return self.peek().type == ttype

    def match(self, ttype: TokenType) -> Optional[Token]:
        if self.check(ttype):
            return self.advance()
        return None

    def expect(self, ttype: TokenType) -> Token:
        token = self.peek()
        if token.type != ttype:
            expected = ttype.name
            got = token.type.name
            msg = f"Expected {expected}, got {got}"

            if ttype == TokenType.ASSIGN and token.type == TokenType.EQ:
                msg += "\n  hint: use = for assignment, == for comparison"
            elif ttype == TokenType.IDENT and token.type == TokenType.FN:
                msg += "\n  hint: nested function definitions are not supported"
            elif ttype == TokenType.RPAREN and token.type == TokenType.NEWLINE:
                msg += "\n  hint: check for missing closing parenthesis"

            raise ParseError(msg, token)
        return self.advance()

    def skip_newlines(self):
        while self.peek().type == TokenType.NEWLINE:
            self.advance()

    # --- Synchronization (error recovery) ---

    SYNC_TOKENS = {TokenType.FN, TokenType.TYPE, TokenType.LET, TokenType.MATCH, TokenType.EOF}

    def synchronize(self):
        """Skip tokens until we find a synchronization point."""
        while self.peek().type != TokenType.EOF:
            if self.peek().type in self.SYNC_TOKENS:
                return
            self.advance()

    # --- Program ---

    def parse_program(self) -> Program:
        imports = []
        defs = []
        trailing_exprs = []
        package = None
        self.skip_newlines()
        
        # Parse package declaration (must be first)
        if self.check(TokenType.PACKAGE):
            self.advance()
            parts = [self.expect(TokenType.IDENT).value]
            while self.check(TokenType.DOT):
                self.advance()  # consume dot
                parts.append(self.expect(TokenType.IDENT).value)
            package = ".".join(parts)
            self.skip_newlines()
        
        while self.peek().type != TokenType.EOF:
            try:
                if self.check(TokenType.IMPORT):
                    imports.append(self.parse_import())
                elif self.check(TokenType.PUB):
                    self.advance()  # consume pub
                    if self.check(TokenType.FN):
                        fn_def = self.parse_fn_def()
                        fn_def.pub = True
                        defs.append(fn_def)
                    elif self.check(TokenType.LET):
                        let_binding = self.parse_let_binding()
                        let_binding.pub = True
                        defs.append(let_binding)
                    elif self.check(TokenType.TYPE):
                        type_def = self.parse_type_def()
                        type_def.pub = True
                        defs.append(type_def)
                    elif self.check(TokenType.IDENT):
                        # pub NAME = expr (shorthand let binding)
                        name = self.expect(TokenType.IDENT).value
                        self.expect(TokenType.ASSIGN)
                        value = self.parse_expr()
                        defs.append(LetBinding(name, value, pub=True, loc=loc_from_token(self.peek(), self.file)))
                    else:
                        raise ParseError(f"Expected fn, let, type, or identifier after pub", self.peek())
                elif self.check(TokenType.TYPE):
                    defs.append(self.parse_type_def())
                elif self.check(TokenType.COMPILETIME):
                    # comptime fn name args = body
                    start = loc_from_token(self.peek(), self.file)
                    self.advance()
                    if self.check(TokenType.FN):
                        fn_def = self.parse_fn_def()
                        fn_def.comptime = True
                        fn_def.loc = start
                        defs.append(fn_def)
                    else:
                        # comptime expression - wrap in let binding
                        expr = self.parse_expr()
                        defs.append(LetBinding(f"_comptime_{len(defs)}", expr, loc=start))
                elif self.check(TokenType.FN):
                    fn_def = self.parse_fn_def()
                    # Handle type annotation-only def followed by actual def
                    # Handle type annotation-only def followed by actual def
                    if (fn_def.params == [] and isinstance(fn_def.body, Block)
                            and len(fn_def.body.exprs) == 0 and fn_def.type_ann is not None):
                        self.skip_newlines()
                        if self.check(TokenType.FN):
                            next_fn = self.parse_fn_def()
                            if next_fn.name == fn_def.name:
                                next_fn.type_ann = fn_def.type_ann
                                fn_def = next_fn
                    defs.append(fn_def)
                elif self.check(TokenType.LET):
                    let_binding = self.parse_let_binding()
                    defs.append(let_binding)
                elif self.check(TokenType.MODULE):
                    defs.append(self.parse_module_def())
                elif self.peek().type in (TokenType.PRINTLN, TokenType.INSPECT, TokenType.PANIC):
                    trailing_exprs.append(self.parse_expr())
                else:
                    raise ParseError(f"Unexpected token: {self.peek().type.name}", self.peek())
            except ParseError as e:
                self.errors.append(e)
                self.synchronize()
            self.skip_newlines()

        # Wrap trailing expressions in synthetic main
        if trailing_exprs:
            has_main = any(isinstance(d, FnDef) and d.name == 'main' for d in defs)
            if not has_main:
                body = trailing_exprs[0] if len(trailing_exprs) == 1 else Block(trailing_exprs)
                defs.append(FnDef('main', [], body))

        return Program(imports, defs, package)

    # --- Top-level definitions ---

    def parse_import(self) -> Import:
        start = loc_from_token(self.peek(), self.file)
        self.expect(TokenType.IMPORT)

        # Parse hierarchical path (e.g., std.collections.list)
        if self.check(TokenType.IDENT):
            path_parts = [self.advance().value]
            while self.check(TokenType.DOT):
                # Check if DOT is followed by LBRACE (selective import) or AS (alias)
                if self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].type in (TokenType.LBRACE, TokenType.AS):
                    break
                self.advance()  # consume dot
                path_parts.append(self.expect(TokenType.IDENT).value)
            path = ".".join(path_parts)
        elif self.check(TokenType.STRING):
            path = self.advance().value
        else:
            raise ParseError("Expected identifier or string after import", self.peek())

        # Parse selective imports: import math.{sin, cos, PI}
        # May have a trailing DOT before the brace (e.g., math.{sin})
        if self.check(TokenType.DOT) and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].type == TokenType.LBRACE:
            self.advance()  # consume dot before {
        selective = None
        if self.check(TokenType.LBRACE):
            self.advance()  # consume {
            selective = []
            while not self.check(TokenType.RBRACE):
                selective.append(self.expect(TokenType.IDENT).value)
                if not self.check(TokenType.RBRACE):
                    self.expect(TokenType.COMMA)
            self.expect(TokenType.RBRACE)

        # Parse alias: import math as m
        alias = None
        if self.check(TokenType.AS):
            self.advance()
            alias = self.expect(TokenType.IDENT).value

        return Import(path, alias, selective, loc=start)

    def parse_type_def(self) -> TypeDef:
        start = loc_from_token(self.peek(), self.file)
        self.expect(TokenType.TYPE)
        name = self.expect(TokenType.IDENT).value

        # Parse type parameters (lowercase IDENTs before '=')
        type_params = []
        while self.check(TokenType.IDENT) and self.peek().value[0].islower():
            type_params.append(self.advance().value)

        self.expect(TokenType.ASSIGN)

        constructors = [self.parse_type_constructor()]
        while self.match(TokenType.PIPE):
            constructors.append(self.parse_type_constructor())

        return TypeDef(name, type_params, constructors, loc=start)

    def parse_type_constructor(self) -> TypeConstructor:
        name = self.expect(TokenType.IDENT).value
        field_types = []
        while True:
            if self.check(TokenType.STAR):
                self.advance()
                field_types.append("_")  # wildcard → fresh type var
            elif self.check(TokenType.IDENT):
                # Could be a type param or concrete type name
                field_types.append(self.peek().value)
                self.advance()
            elif self.check(TokenType.LPAREN):
                # Parenthesized type expression like (List a)
                self.advance()
                inner = self.parse_type_constructor()
                # For now, just store as "T(...)" — typecheck will resolve
                field_types.append(f"({inner.name} {' '.join(inner.field_types)})")
                self.expect(TokenType.RPAREN)
            else:
                break
        return TypeConstructor(name, len(field_types), field_types)

    def parse_module_def(self) -> ModuleDef:
        start = loc_from_token(self.peek(), self.file)
        self.expect(TokenType.MODULE)
        name = self.expect(TokenType.IDENT).value
        self.expect(TokenType.LBRACE)
        self.skip_newlines()
        
        definitions = []
        while not self.check(TokenType.RBRACE):
            if self.check(TokenType.FN):
                pub = False
                if self.check(TokenType.PUB):
                    self.advance()
                    pub = True
                fn_def = self.parse_fn_def()
                fn_def.pub = pub
                definitions.append(fn_def)
            elif self.check(TokenType.TYPE):
                pub = False
                if self.check(TokenType.PUB):
                    self.advance()
                    pub = True
                type_def = self.parse_type_def()
                type_def.pub = pub
                definitions.append(type_def)
            elif self.check(TokenType.LET):
                pub = False
                if self.check(TokenType.PUB):
                    self.advance()
                    pub = True
                let_binding = self.parse_let_binding()
                let_binding.pub = pub
                definitions.append(let_binding)
            elif self.check(TokenType.MODULE):
                definitions.append(self.parse_module_def())
            else:
                raise ParseError(f"Unexpected token in module: {self.peek().type.name}", self.peek())
            self.skip_newlines()
        
        self.expect(TokenType.RBRACE)
        return ModuleDef(name, definitions, loc=start)

    def parse_fn_def(self) -> FnDef:
        start = loc_from_token(self.peek(), self.file)
        self.expect(TokenType.FN)
        name = self.expect(TokenType.IDENT).value

        # Check for type annotation: fn name : Type -> Type
        type_ann = None
        if self.check(TokenType.COLON):
            self.advance()
            self.skip_newlines()
            type_ann = self.parse_type_expr()
            return FnDef(name, [], Block([]), type_ann, loc=start)

        # Parse parameters (positional and named)
        params = []
        named_params = []
        while self.check(TokenType.IDENT) or self.check(TokenType.UNDERSCORE) or self.check(TokenType.TILDE):
            if self.check(TokenType.TILDE):
                self.advance()  # consume ~
                named_params.append(self.expect(TokenType.IDENT).value)
            else:
                params.append(self.advance().value)

        self.expect(TokenType.ASSIGN)
        self.skip_newlines()
        body = self.parse_block()

        return FnDef(name, params, body, type_ann, loc=start, named_params=named_params if named_params else None)

    def parse_let_binding(self) -> LetBinding:
        start = loc_from_token(self.peek(), self.file)
        self.expect(TokenType.LET)
        name = self.expect(TokenType.IDENT).value
        self.expect(TokenType.ASSIGN)
        value = self.parse_expr()
        return LetBinding(name, value, loc=start)

    # --- Type expressions ---

    def parse_type_expr(self) -> TypeExpr:
        left = self.parse_type_atom()
        if self.match(TokenType.ARROW):
            self.skip_newlines()
            right = self.parse_type_expr()
            return TypeArrow(left, right)
        return left

    def parse_type_atom(self) -> TypeExpr:
        tok = self.peek()

        if tok.type == TokenType.IDENT:
            name = self.advance().value

            # Check for type application: List a, Maybe Int, etc.
            args = []
            while self.peek().type in (TokenType.IDENT, TokenType.LPAREN):
                if self.peek().type == TokenType.ARROW:
                    break
                args.append(self.parse_type_atom())

            if args:
                return TypeApp(name, args)

            if name == "Int": return TypeInt()
            elif name == "Float": return TypeFloat()
            elif name == "Bool": return TypeBool()
            elif name == "String": return TypeString()
            elif name == "Char": return TypeChar()
            elif name == "Unit": return TypeUnit()
            else: return TypeVar(name)

        elif tok.type == TokenType.LPAREN:
            self.advance()
            self.skip_newlines()
            first = self.parse_type_expr()
            # Check for tuple type: (Int, String)
            if self.check(TokenType.COMMA):
                elements = [first]
                while self.match(TokenType.COMMA):
                    self.skip_newlines()
                    elements.append(self.parse_type_expr())
                self.expect(TokenType.RPAREN)
                return TupleType(elements)
            self.expect(TokenType.RPAREN)
            return first

        return TypeUnit()

    # --- Block parsing ---

    def parse_block(self, stop_tokens=None, if_col=None) -> Expr:
        """Parse a sequence of expressions separated by newlines.
        Last expression is the value."""
        if stop_tokens is None:
            stop_tokens = {TokenType.FN, TokenType.TYPE, TokenType.PUB}
        self.skip_newlines()
        exprs = []

        while self.peek().type != TokenType.EOF:
            if self.peek().type in stop_tokens:
                break
            # Stop at ELSE that belongs to the same or outer if
            if if_col is not None and self.peek().type == TokenType.ELSE and self.peek().col <= if_col:
                break
            if self.check(TokenType.LET):
                self.advance()
                self.skip_newlines()
                # Check for tuple destructuring: let (x, y) = ...
                if self.check(TokenType.LPAREN):
                    # Save position to parse as pattern
                    pat = self.parse_pattern()
                    # pat should be PatTuple
                    if hasattr(pat, 'elements'):
                        name = "(" + ", ".join(
                            e.name if hasattr(e, 'name') else str(e.value)
                            for e in pat.elements
                        ) + ")"
                    else:
                        name = str(pat.value) if hasattr(pat, 'value') else str(pat)
                else:
                    name = self.expect(TokenType.IDENT).value
                self.expect(TokenType.ASSIGN)
                value = self.parse_expr()
                self.skip_newlines()
                # Parse the rest of the block as the let's body
                body = self.parse_block(stop_tokens, if_col)
                return LetExpr(name, value, body) if not exprs else Block(exprs + [LetExpr(name, value, body)])
            elif self.check(TokenType.NEWLINE):
                self.advance()
                self.skip_newlines()
            else:
                expr = self.parse_expr()
                exprs.append(expr)
                self.skip_newlines()

        if not exprs:
            return Block([])
        if len(exprs) == 1:
            return exprs[0]
        return Block(exprs)

    # --- Expression parsing (precedence climbing) ---

    def parse_expr(self) -> Expr:
        self.skip_newlines()
        if self.check(TokenType.COMPILETIME):
            start = loc_from_token(self.peek(), self.file)
            self.advance()
            expr = self.parse_expr()
            return ComptimeExpr(expr, loc=start)
        return self.parse_pipe()

    def parse_pipe(self) -> Expr:
        """Parse pipe operator |> (left-associative, lowest precedence).
        x |> f |> g  desugars to  g(f(x))"""
        left = self.parse_if()
        while self.check(TokenType.PIPE_GT):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            self.advance()
            right = self.parse_if()
            # x |> f  →  f(x)
            left = FnCall(right, [left], loc=start)
        return left

    def parse_if(self) -> Expr:
        if self.check(TokenType.IF):
            start = loc_from_token(self.peek(), self.file)
            if_col = self.peek().col
            self.advance()
            cond = self.parse_expr()
            self.skip_newlines()
            self.expect(TokenType.THEN)
            self.skip_newlines()
            then_branch = self.parse_block(stop_tokens={TokenType.ELSE}, if_col=if_col)
            else_branch = None
            self.skip_newlines()
            if self.check(TokenType.ELSE):
                else_line = self.peek().line
                self.advance()
                self.skip_newlines()
                # Single-line else: parse single expression (avoids consuming outer else or match arms)
                # Multi-line else: parse block of expressions
                if self.peek().line > else_line:
                    else_branch = self.parse_block(stop_tokens={TokenType.FN, TokenType.TYPE})
                else:
                    else_branch = self.parse_expr()
            return IfExpr(cond, then_branch, else_branch, loc=start)
        return self.parse_match()

    def parse_match(self) -> Expr:
        if not self.check(TokenType.MATCH):
            return self.parse_or()

        start = loc_from_token(self.peek(), self.file)
        self.advance()

        # Parse the match value (stop before eating constructor patterns)
        value = self._parse_match_value()
        self.skip_newlines()

        # Parse match arms
        arms = []
        first_arm_col = None
        while self.peek().type != TokenType.EOF:
            # Skip PIPE at start of match arm
            if self.check(TokenType.PIPE):
                self.advance()
                self.skip_newlines()

            # Check if this looks like a new arm pattern
            if not self._looks_like_pattern():
                break

            # Check indentation: arm must be indented at least as much as the first arm
            if first_arm_col is not None and self.peek().col < first_arm_col:
                break

            if first_arm_col is None:
                first_arm_col = self.peek().col

            pattern = self.parse_pattern()
            self.expect(TokenType.ARROW)
            self.skip_newlines()

            # Parse arm body
            body = self._parse_match_arm_body(first_arm_col)
            arms.append(MatchArm(pattern, body))

        return MatchExpr(value, arms, loc=start)

    def _parse_match_value(self) -> Expr:
        """Parse match value expression. Stop before eating constructor patterns as args."""
        expr = self.parse_primary()

        # Check for := (set ref)
        if self.check(TokenType.COLON_EQ):
            start = expr.loc if hasattr(expr, 'loc') and expr.loc else None
            self.advance()
            value = self.parse_expr()
            return SetExpr(expr, value, loc=start)

        # Function application, but stop before anything that looks like a match arm pattern
        # (constructor args, wildcards, literal patterns, or patterns followed by ->)
        args = []
        while self.peek().type in (TokenType.INT, TokenType.FLOAT, TokenType.STRING,
                                    TokenType.CHAR, TokenType.TRUE, TokenType.FALSE,
                                    TokenType.IDENT, TokenType.LPAREN, TokenType.UNDERSCORE,
                                    TokenType.DOLLAR_LBRACE, TokenType.BANG, TokenType.REF):
            # Stop if the current position looks like a new match arm
            if self._looks_like_pattern() and self._is_new_arm():
                break
            args.append(self.parse_primary())

        if args:
            loc = expr.loc if hasattr(expr, 'loc') and expr.loc else None
            return FnCall(expr, args, loc=loc)
        return expr

    def _parse_match_arm_body(self, match_col: int = 0) -> Expr:
        """Parse the body of a match arm. Stop at next arm or end of match."""
        exprs = []
        let_chain = None

        while self.peek().type != TokenType.EOF:
            if self._is_match_arm_stop(match_col):
                break

            # Stop if current token is at the same or shallower indentation as match arms
            # (unless it's part of a nested construct like a block)
            if match_col > 0 and self.peek().col <= match_col and not self._is_nested_construct():
                break

            if self.check(TokenType.LET):
                self.advance()
                name = self.expect(TokenType.IDENT).value
                self.expect(TokenType.ASSIGN)
                value = self.parse_expr()
                self.skip_newlines()
                let_expr = LetExpr(name, value, None)
                if let_chain is None:
                    let_chain = let_expr
                else:
                    current = let_chain
                    while current.body is not None and isinstance(current.body, LetExpr):
                        current = current.body
                    current.body = let_expr
            elif self.check(TokenType.NEWLINE):
                self.advance()
                self.skip_newlines()
            else:
                exprs.append(self.parse_expr())
                self.skip_newlines()

        # Combine let chain with body expressions
        if let_chain is not None:
            current = let_chain
            while current.body is not None and isinstance(current.body, LetExpr):
                current = current.body
            if len(exprs) == 1:
                current.body = exprs[0]
            elif len(exprs) > 1:
                current.body = Block(exprs)
            else:
                current.body = IntLiteral(0)
            return let_chain

        if len(exprs) == 1:
            return exprs[0]
        if len(exprs) > 1:
            return Block(exprs)
        return IntLiteral(0)

    def _is_nested_construct(self) -> bool:
        """Check if current token starts a nested construct (match, if, let, etc.)."""
        t = self.peek()
        return t.type in (TokenType.MATCH, TokenType.IF, TokenType.LET, TokenType.LBRACKET,
                          TokenType.LPAREN, TokenType.BACKSLASH)

    def _looks_like_pattern(self) -> bool:
        """Check if current token could start a match arm pattern."""
        t = self.peek()
        if t.type == TokenType.UNDERSCORE:
            return True
        if t.type in (TokenType.INT, TokenType.STRING, TokenType.TRUE, TokenType.FALSE):
            return True
        if t.type == TokenType.IDENT:
            return True
        if t.type == TokenType.LPAREN:
            return True
        return False

    def _is_new_arm(self) -> bool:
        """Look ahead to see if current position is a new match arm."""
        if not self._looks_like_pattern():
            return False
        saved_pos = self.pos
        try:
            self.parse_pattern()
            is_arrow = self.peek().type == TokenType.ARROW
            return is_arrow
        except ParseError:
            return False
        finally:
            self.pos = saved_pos

    def _is_match_arm_stop(self, match_col: int = 0) -> bool:
        """Check if current position should end a match arm body."""
        t = self.peek()
        if t.type in (TokenType.RPAREN, TokenType.FN, TokenType.TYPE, TokenType.EOF):
            return True
        # Stop at MATCH only if not nested (at same or shallower indentation)
        if t.type == TokenType.MATCH and match_col > 0 and t.col <= match_col:
            return True
        # Stop at else keyword at match arm indentation (belongs to enclosing if)
        if t.type == TokenType.ELSE and t.col <= match_col:
            return True
        # Stop if we see a pattern at a shallower indentation than the match arms
        if self._looks_like_pattern() and t.col < match_col:
            return True
        if self._is_new_arm():
            return True
        return False

    def parse_or(self) -> Expr:
        left = self.parse_and()
        while self.check(TokenType.OR):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            self.advance()
            right = self.parse_and()
            left = BinaryOp('||', left, right, loc=start)
        return left

    def parse_and(self) -> Expr:
        left = self.parse_comparison()
        while self.check(TokenType.AND):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            self.advance()
            right = self.parse_comparison()
            left = BinaryOp('&&', left, right, loc=start)
        return left

    def parse_comparison(self) -> Expr:
        left = self.parse_cons()
        while self.peek().type in (TokenType.EQ, TokenType.NEQ, TokenType.LT, TokenType.GT, TokenType.LTE, TokenType.GTE):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            op = self.advance().value
            right = self.parse_cons()
            left = BinaryOp(op, left, right, loc=start)
        return left

    def parse_cons(self) -> Expr:
        """Parse cons operator :: (right-associative, between comparison and addition).
        x :: xs  desugars to  Cons(x, xs)"""
        left = self.parse_addition()
        if self.check(TokenType.COLON_COLON):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            self.advance()
            right = self.parse_cons()  # right-associative
            return FnCall(Identifier('Cons', loc=start), [left, right], loc=start)
        return left

    def parse_addition(self) -> Expr:
        left = self.parse_multiplication()
        while self.peek().type in (TokenType.PLUS, TokenType.MINUS):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            op = self.advance().value
            right = self.parse_multiplication()
            left = BinaryOp(op, left, right, loc=start)
        return left

    def parse_multiplication(self) -> Expr:
        left = self.parse_unary()
        while self.peek().type in (TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            start = left.loc if hasattr(left, 'loc') and left.loc else loc_from_token(self.peek(), self.file)
            op = self.advance().value
            right = self.parse_unary()
            left = BinaryOp(op, left, right, loc=start)
        return left

    def parse_unary(self) -> Expr:
        if self.check(TokenType.MINUS):
            start = loc_from_token(self.peek(), self.file)
            self.advance()
            expr = self.parse_unary()
            return UnaryOp('-', expr, loc=start)
        if self.check(TokenType.BANG):
            start = loc_from_token(self.peek(), self.file)
            self.advance()
            expr = self.parse_unary()
            return DerefExpr(expr, loc=start)
        if self.check(TokenType.COMPILETIME):
            start = loc_from_token(self.peek(), self.file)
            self.advance()
            expr = self.parse_unary()
            return ComptimeExpr(expr, loc=start)
        return self.parse_application()

    def parse_application(self) -> Expr:
        expr = self.parse_primary()

        # Check for := (set ref)
        if self.check(TokenType.COLON_EQ):
            start = expr.loc if hasattr(expr, 'loc') and expr.loc else None
            self.advance()
            value = self.parse_expr()
            return SetExpr(expr, value, loc=start)

        # Function application: func arg1 arg2 ... ~name1:expr ~name2:expr
        args = []
        named_args = []
        while self.peek().type in (TokenType.INT, TokenType.FLOAT, TokenType.STRING,
                                    TokenType.CHAR, TokenType.TRUE, TokenType.FALSE,
                                    TokenType.IDENT, TokenType.LPAREN, TokenType.UNDERSCORE,
                                    TokenType.DOLLAR_LBRACE, TokenType.BANG, TokenType.REF,
                                    TokenType.TILDE):
            # Stop if the current position looks like a new match arm
            if self._looks_like_pattern() and self._is_new_arm():
                break
            # Handle named arguments: ~name:expr
            if self.check(TokenType.TILDE):
                self.advance()  # consume ~
                arg_name = self.expect(TokenType.IDENT).value
                self.expect(TokenType.COLON)
                arg_value = self.parse_primary()
                named_args.append(NamedArg(arg_name, arg_value, loc=loc_from_token(self.peek(), self.file)))
            else:
                args.append(self.parse_primary())

        # Also consume - as unary prefix on numeric arguments (e.g. add 5 -60)
        # Only when - follows another argument (not after a primary expression result)
        while self.peek().type == TokenType.MINUS:
            if args and self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1].type in (
                TokenType.INT, TokenType.FLOAT):
                args.append(self.parse_unary())
            else:
                break

        if args or named_args:
            loc = expr.loc if hasattr(expr, 'loc') and expr.loc else None
            return FnCall(expr, args, named_args=named_args if named_args else None, loc=loc)

        return expr

    def parse_primary(self) -> Expr:
        token = self.peek()
        loc = loc_from_token(token, self.file)

        if token.type == TokenType.INT:
            self.advance()
            value = token.value.replace('_', '')
            if value.startswith('0x') or value.startswith('0X'):
                return IntLiteral(int(value, 16), loc=loc)
            elif value.startswith('0b') or value.startswith('0B'):
                return IntLiteral(int(value, 2), loc=loc)
            else:
                return IntLiteral(int(value), loc=loc)

        if token.type == TokenType.FLOAT:
            self.advance()
            return FloatLiteral(float(token.value), loc=loc)

        if token.type == TokenType.STRING:
            self.advance()
            if self.peek().type == TokenType.DOLLAR_LBRACE:
                return self.parse_string_interpolation(token.value)
            return StringLiteral(token.value, loc=loc)

        if token.type == TokenType.DOLLAR_LBRACE:
            return self.parse_string_interpolation("")

        if token.type == TokenType.CHAR:
            self.advance()
            return CharLiteral(token.value, loc=loc)

        if token.type == TokenType.TRUE:
            self.advance()
            return BoolLiteral(True, loc=loc)

        if token.type == TokenType.FALSE:
            self.advance()
            return BoolLiteral(False, loc=loc)

        if token.type == TokenType.IDENT:
            self.advance()
            expr = Identifier(token.value, loc=loc)
            # Check for field access: ident.field
            while self.check(TokenType.DOT) and self.pos + 1 < len(self.tokens):
                next_token = self.tokens[self.pos + 1]
                if next_token.type == TokenType.INT:
                    # Tuple field access: expr.0, expr.1, etc.
                    self.advance()  # .
                    idx_tok = self.advance()
                    idx = int(idx_tok.value)
                    expr = FnCall(Identifier(f'tuple_{idx}'), [expr], loc=loc)
                elif next_token.type == TokenType.IDENT:
                    # Module/type field access: expr.field
                    self.advance()  # .
                    field_name = self.advance().value
                    expr = FieldAccess(expr, field_name, loc=loc)
                else:
                    break
            return expr

        if token.type in (TokenType.PRINTLN, TokenType.INSPECT, TokenType.PANIC):
            self.advance()
            expr = Identifier(token.value, loc=loc)
            # Check for field access: println.field (unusual but possible)
            while self.check(TokenType.DOT) and self.pos + 1 < len(self.tokens):
                next_token = self.tokens[self.pos + 1]
                if next_token.type == TokenType.INT:
                    self.advance()  # .
                    idx_tok = self.advance()
                    idx = int(idx_tok.value)
                    expr = FnCall(Identifier(f'tuple_{idx}'), [expr], loc=loc)
                elif next_token.type == TokenType.IDENT:
                    self.advance()  # .
                    field_name = self.advance().value
                    expr = FieldAccess(expr, field_name, loc=loc)
                else:
                    break
            return expr

        if token.type == TokenType.UNDERSCORE:
            self.advance()
            return Wildcard(loc=loc)

        if token.type == TokenType.LPAREN:
            self.advance()
            self.skip_newlines()
            first = self.parse_expr()
            # Check for tuple: (a, b, c)
            if self.check(TokenType.COMMA):
                elements = [first]
                while self.match(TokenType.COMMA):
                    self.skip_newlines()
                    elements.append(self.parse_expr())
                self.expect(TokenType.RPAREN)
                return TupleExpr(elements, loc=loc)
            # Otherwise just a parenthesized expression
            self.expect(TokenType.RPAREN)
            return first

        if token.type == TokenType.BACKSLASH:
            self.advance()
            params = []
            while self.check(TokenType.IDENT) or self.check(TokenType.UNDERSCORE):
                params.append(self.advance().value)
            self.expect(TokenType.ARROW)
            self.skip_newlines()
            body = self.parse_expr()
            return Lambda(params, body, loc=loc)

        if token.type == TokenType.REF:
            self.advance()
            value = self.parse_primary()
            return RefExpr(value, loc=loc)

        if token.type == TokenType.BANG:
            self.advance()
            ref = self.parse_primary()
            return DerefExpr(ref, loc=loc)

        if token.type == TokenType.LBRACKET:
            self.advance()
            elements = []
            if not self.check(TokenType.RBRACKET):
                elements.append(self.parse_expr())
                while self.match(TokenType.COMMA):
                    self.skip_newlines()
                    elements.append(self.parse_expr())
            self.expect(TokenType.RBRACKET)
            # Desugar [a, b, c] to Cons a (Cons b (Cons c Nil))
            result = Identifier('Nil')
            for elem in reversed(elements):
                result = FnCall(Identifier('Cons'), [elem, result])
            return result

        raise ParseError(f"Unexpected token in expression: {token.type.name}", token)

    # --- String interpolation ---

    def parse_string_interpolation(self, prefix: str) -> Expr:
        """Parse string interpolation: "prefix${expr}rest"
        Desugars to: concat "prefix" (concat (to_string expr) "rest")
        """
        parts = []

        if prefix:
            parts.append(StringLiteral(prefix))

        self.expect(TokenType.DOLLAR_LBRACE)
        expr = self.parse_expr()
        self.expect(TokenType.RBRACE)

        to_string_call = FnCall(Identifier('to_string'), [expr])
        parts.append(to_string_call)

        while True:
            if self.check(TokenType.STRING):
                token = self.advance()
                if token.value:
                    parts.append(StringLiteral(token.value))
                if self.peek().type == TokenType.DOLLAR_LBRACE:
                    continue
                break
            elif self.peek().type == TokenType.DOLLAR_LBRACE:
                self.expect(TokenType.DOLLAR_LBRACE)
                expr = self.parse_expr()
                self.expect(TokenType.RBRACE)
                to_string_call = FnCall(Identifier('to_string'), [expr])
                parts.append(to_string_call)
            else:
                break

        if len(parts) == 1:
            return parts[0]

        result = parts[0]
        for part in parts[1:]:
            result = FnCall(Identifier('concat'), [result, part])

        return result

    # --- Patterns ---

    def parse_pattern(self) -> Pattern:
        token = self.peek()
        loc = loc_from_token(token, self.file)

        if token.type == TokenType.UNDERSCORE:
            self.advance()
            return PatWildcard(loc=loc)

        if token.type == TokenType.LPAREN:
            self.advance()
            self.skip_newlines()
            first = self.parse_pattern()
            # Check for tuple pattern: (x, y)
            if self.check(TokenType.COMMA):
                elements = [first]
                while self.match(TokenType.COMMA):
                    self.skip_newlines()
                    elements.append(self.parse_pattern())
                self.expect(TokenType.RPAREN)
                return PatTuple(elements, loc=loc)
            # Single pattern in parens — consume RPAREN and return the inner pattern
            self.expect(TokenType.RPAREN)
            return first

        if token.type == TokenType.INT:
            self.advance()
            return PatLiteral(int(token.value.replace('_', '')), loc=loc)

        if token.type == TokenType.STRING:
            self.advance()
            return PatLiteral(token.value, loc=loc)

        if token.type == TokenType.TRUE:
            self.advance()
            return PatLiteral(True, loc=loc)

        if token.type == TokenType.FALSE:
            self.advance()
            return PatLiteral(False, loc=loc)

        if token.type == TokenType.IDENT:
            self.advance()
            name = token.value
            # Uppercase names are constructors — may have args
            if name[0:1].isupper():
                args = []
                while self.peek().type in (TokenType.IDENT, TokenType.INT, TokenType.STRING,
                                            TokenType.TRUE, TokenType.FALSE, TokenType.UNDERSCORE, TokenType.LPAREN):
                    args.append(self.parse_pattern())
                return PatConstructor(name, args, loc=loc)
            return PatIdent(name, loc=loc)

        raise ParseError(f"Unexpected token in pattern: {token.type.name}", token)


# ============================================================
# Public API
# ============================================================

def parse(tokens: List[Token], file: str = "<input>") -> Program:
    return Parser(tokens, file).parse_program()
