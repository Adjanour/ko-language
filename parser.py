"""Kō Parser - Recursive descent parser for the Kō language"""

from dataclasses import dataclass, field
from typing import List, Optional, Union
from enum import Enum, auto
from lexer import Token, TokenType, LexerError


# AST Nodes

@dataclass
class IntLiteral:
    value: int

@dataclass
class FloatLiteral:
    value: float

@dataclass
class StringLiteral:
    value: str

@dataclass
class CharLiteral:
    value: str

@dataclass
class BoolLiteral:
    value: bool

@dataclass
class Identifier:
    name: str

@dataclass
class Wildcard:
    pass

@dataclass
class BinaryOp:
    op: str
    left: 'Expr'
    right: 'Expr'

@dataclass
class UnaryOp:
    op: str
    expr: 'Expr'

@dataclass
class FnCall:
    func: 'Expr'
    args: List['Expr']

@dataclass
class IfExpr:
    cond: 'Expr'
    then_branch: 'Expr'
    else_branch: Optional['Expr']

@dataclass
class MatchArm:
    pattern: 'Pattern'
    body: 'Expr'

@dataclass
class MatchExpr:
    value: 'Expr'
    arms: List[MatchArm]

@dataclass
class Block:
    exprs: List['Expr']

@dataclass
class LetExpr:
    name: str
    value: 'Expr'
    body: 'Expr'

@dataclass
class FnDef:
    name: str
    params: List[str]
    body: 'Expr'

@dataclass
class LetBinding:
    name: str
    value: 'Expr'

@dataclass
class TypeDef:
    name: str
    constructors: List['TypeConstructor']

@dataclass
class TypeConstructor:
    name: str
    fields: int  # number of * placeholders

@dataclass
class Program:
    definitions: List[Union[FnDef, LetBinding, TypeDef]]


# Patterns

@dataclass
class PatLiteral:
    value: Union[int, float, str, bool]

@dataclass
class PatIdent:
    name: str

@dataclass
class PatWildcard:
    pass

@dataclass
class PatConstructor:
    name: str
    args: List['Pattern']

Pattern = Union[PatLiteral, PatIdent, PatWildcard, PatConstructor]
Expr = Union[IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
             Identifier, Wildcard, BinaryOp, UnaryOp, FnCall, IfExpr, MatchExpr,
             Block, LetExpr]


class ParseError(Exception):
    def __init__(self, msg, token):
        super().__init__(f"Parse error at {token.line}:{token.col}: {msg}")
        self.token = token


class Parser:
    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

    def peek(self) -> Token:
        return self.tokens[self.pos]

    def advance(self) -> Token:
        token = self.tokens[self.pos]
        self.pos += 1
        return token

    def expect(self, type: TokenType) -> Token:
        token = self.peek()
        if token.type != type:
            raise ParseError(f"Expected {type.name}, got {token.type.name}", token)
        return self.advance()

    def skip_newlines(self):
        while self.peek().type == TokenType.NEWLINE:
            self.advance()

    def parse_program(self) -> Program:
        defs = []
        trailing_exprs = []
        self.skip_newlines()
        while self.peek().type != TokenType.EOF:
            if self.peek().type == TokenType.TYPE:
                defs.append(self.parse_type_def())
            elif self.peek().type == TokenType.FN:
                defs.append(self.parse_fn_def())
            elif self.peek().type == TokenType.LET:
                defs.append(self.parse_let_binding())
            elif self.peek().type in (TokenType.PRINTLN, TokenType.INSPECT, TokenType.PANIC):
                # Top-level expression statement
                trailing_exprs.append(self.parse_expr())
            else:
                raise ParseError(f"Unexpected token: {self.peek().type.name}", self.peek())
            self.skip_newlines()

        # If there are trailing expressions, wrap them in a synthetic main
        if trailing_exprs:
            has_main = any(isinstance(d, FnDef) and d.name == 'main' for d in defs)
            if not has_main:
                if len(trailing_exprs) == 1:
                    body = trailing_exprs[0]
                else:
                    body = Block(trailing_exprs)
                defs.append(FnDef('main', [], body))

        return Program(defs)

    def parse_type_def(self) -> TypeDef:
        self.expect(TokenType.TYPE)
        name = self.expect(TokenType.IDENT).value
        self.expect(TokenType.ASSIGN)

        constructors = []
        constructors.append(self.parse_type_constructor())

        while self.peek().type == TokenType.PIPE:
            self.advance()
            constructors.append(self.parse_type_constructor())

        return TypeDef(name, constructors)

    def parse_type_constructor(self) -> 'TypeConstructor':
        name = self.expect(TokenType.IDENT).value
        fields = 0
        while self.peek().type == TokenType.STAR:
            self.advance()
            fields += 1
        return TypeConstructor(name, fields)

    def parse_fn_def(self) -> FnDef:
        self.expect(TokenType.FN)
        name = self.expect(TokenType.IDENT).value

        params = []
        while self.peek().type == TokenType.IDENT:
            params.append(self.advance().value)

        self.expect(TokenType.ASSIGN)
        self.skip_newlines()
        body = self.parse_block()

        return FnDef(name, params, body)

    def parse_let_binding(self) -> LetBinding:
        self.expect(TokenType.LET)
        name = self.expect(TokenType.IDENT).value
        self.expect(TokenType.ASSIGN)
        value = self.parse_expr()
        return LetBinding(name, value)

    def parse_block(self) -> Expr:
        """Parse a sequence of expressions, separated by newlines. Last expression is the value."""
        self.skip_newlines()
        exprs = []
        let_chain = None  # Track the chain of let bindings

        while self.peek().type != TokenType.EOF:
            if self.peek().type == TokenType.LET:
                self.advance()
                name = self.expect(TokenType.IDENT).value
                self.expect(TokenType.ASSIGN)
                value = self.parse_expr()
                self.skip_newlines()
                # Create a placeholder LetExpr - body will be filled later
                let_expr = LetExpr(name, value, None)
                if let_chain is None:
                    let_chain = let_expr
                else:
                    # Find the end of the chain and append
                    current = let_chain
                    while current.body is not None and isinstance(current.body, LetExpr):
                        current = current.body
                    current.body = let_expr
            elif self.peek().type == TokenType.NEWLINE:
                self.advance()
                self.skip_newlines()
            elif self.peek().type in (TokenType.INSPECT, TokenType.PRINTLN):
                # Handle inspect and println as expressions
                expr = self.parse_expr()
                exprs.append(expr)
                self.skip_newlines()
            else:
                expr = self.parse_expr()
                exprs.append(expr)
                self.skip_newlines()
                # Continue if we see anything that could start a new expression
                # Stop only on EOF, FN, TYPE which are top-level
                if self.peek().type not in (TokenType.EOF, TokenType.FN, TokenType.TYPE):
                    continue
                break

        # Combine let chain with remaining expressions
        if let_chain is not None:
            # Find the end of the let chain
            current = let_chain
            while current.body is not None and isinstance(current.body, LetExpr):
                current = current.body
            # Set the body to be the remaining expressions
            if len(exprs) == 1:
                current.body = exprs[0]
            elif len(exprs) > 1:
                current.body = Block(exprs)
            else:
                current.body = IntLiteral(0)  # Unit value
            return let_chain

        if not exprs:
            return Block([])
        if len(exprs) == 1:
            return exprs[0]
        return Block(exprs)

    def parse_expr(self) -> Expr:
        return self.parse_if()

    def parse_if(self) -> Expr:
        if self.peek().type == TokenType.IF:
            self.advance()
            cond = self.parse_expr()
            self.expect(TokenType.THEN)
            self.skip_newlines()
            then_branch = self.parse_expr()
            else_branch = None
            self.skip_newlines()
            if self.peek().type == TokenType.ELSE:
                self.advance()
                self.skip_newlines()
                else_branch = self.parse_expr()
            return IfExpr(cond, then_branch, else_branch)
        return self.parse_match()

    def parse_match(self) -> Expr:
        if self.peek().type == TokenType.MATCH:
            self.advance()
            value = self.parse_expr()
            self.skip_newlines()
            arms = []
            while self.peek().type != TokenType.EOF and self.peek().type not in (TokenType.NEWLINE, TokenType.RPAREN, TokenType.FN, TokenType.TYPE):
                pattern = self.parse_pattern()
                self.expect(TokenType.ARROW)
                self.skip_newlines()
                body = self.parse_expr()
                arms.append(MatchArm(pattern, body))
                self.skip_newlines()
            return MatchExpr(value, arms)
        return self.parse_or()

    def parse_or(self) -> Expr:
        left = self.parse_and()
        while self.peek().type == TokenType.OR:
            self.advance()
            right = self.parse_and()
            left = BinaryOp('||', left, right)
        return left

    def parse_and(self) -> Expr:
        left = self.parse_comparison()
        while self.peek().type == TokenType.AND:
            self.advance()
            right = self.parse_comparison()
            left = BinaryOp('&&', left, right)
        return left

    def parse_comparison(self) -> Expr:
        left = self.parse_addition()
        while self.peek().type in (TokenType.EQ, TokenType.NEQ, TokenType.LT, TokenType.GT, TokenType.LTE, TokenType.GTE):
            op = self.advance().value
            right = self.parse_addition()
            left = BinaryOp(op, left, right)
        return left

    def parse_addition(self) -> Expr:
        left = self.parse_multiplication()
        while self.peek().type in (TokenType.PLUS, TokenType.MINUS):
            op = self.advance().value
            right = self.parse_multiplication()
            left = BinaryOp(op, left, right)
        return left

    def parse_multiplication(self) -> Expr:
        left = self.parse_unary()
        while self.peek().type in (TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            op = self.advance().value
            right = self.parse_unary()
            left = BinaryOp(op, left, right)
        return left

    def parse_unary(self) -> Expr:
        if self.peek().type == TokenType.MINUS:
            self.advance()
            expr = self.parse_unary()
            return UnaryOp('-', expr)
        if self.peek().type == TokenType.NOT:
            self.advance()
            expr = self.parse_unary()
            return UnaryOp('!', expr)
        return self.parse_application()

    def parse_application(self) -> Expr:
        expr = self.parse_primary()

        # Function application: func arg1 arg2 ...
        # Collect all arguments and create a single FnCall
        args = []
        while self.peek().type in (TokenType.INT, TokenType.FLOAT, TokenType.STRING,
                                    TokenType.CHAR, TokenType.TRUE, TokenType.FALSE,
                                    TokenType.IDENT, TokenType.LPAREN, TokenType.UNDERSCORE):
            args.append(self.parse_primary())

        if args:
            return FnCall(expr, args)
        return expr

    def parse_primary(self) -> Expr:
        token = self.peek()

        if token.type == TokenType.INT:
            self.advance()
            # Handle hex (0x), binary (0b), and decimal with underscores
            value = token.value.replace('_', '')
            if value.startswith('0x') or value.startswith('0X'):
                return IntLiteral(int(value, 16))
            elif value.startswith('0b') or value.startswith('0B'):
                return IntLiteral(int(value, 2))
            else:
                return IntLiteral(int(value))

        if token.type == TokenType.FLOAT:
            self.advance()
            return FloatLiteral(float(token.value))

        if token.type == TokenType.STRING:
            self.advance()
            return StringLiteral(token.value)

        if token.type == TokenType.CHAR:
            self.advance()
            return CharLiteral(token.value)

        if token.type == TokenType.TRUE:
            self.advance()
            return BoolLiteral(True)

        if token.type == TokenType.FALSE:
            self.advance()
            return BoolLiteral(False)

        if token.type == TokenType.IDENT:
            self.advance()
            return Identifier(token.value)

        # Handle built-in functions as identifiers
        if token.type in (TokenType.PRINTLN, TokenType.INSPECT):
            self.advance()
            return Identifier(token.value)

        if token.type == TokenType.UNDERSCORE:
            self.advance()
            return Wildcard()

        if token.type == TokenType.LPAREN:
            self.advance()
            expr = self.parse_expr()
            self.expect(TokenType.RPAREN)
            return expr

        raise ParseError(f"Unexpected token in expression: {token.type.name}", token)

    def parse_pattern(self) -> Pattern:
        token = self.peek()

        if token.type == TokenType.UNDERSCORE:
            self.advance()
            return PatWildcard()

        if token.type == TokenType.INT:
            self.advance()
            return PatLiteral(int(token.value))

        if token.type == TokenType.STRING:
            self.advance()
            return PatLiteral(token.value)

        if token.type == TokenType.TRUE:
            self.advance()
            return PatLiteral(True)

        if token.type == TokenType.FALSE:
            self.advance()
            return PatLiteral(False)

        if token.type == TokenType.IDENT:
            self.advance()
            name = token.value
            # Uppercase names are constructors - may have args
            # Lowercase names are variable bindings - no args consumed
            if name[0].isupper():
                args = []
                while self.peek().type in (TokenType.IDENT, TokenType.INT, TokenType.STRING,
                                            TokenType.TRUE, TokenType.FALSE, TokenType.UNDERSCORE, TokenType.LPAREN):
                    # Stop if we see an uppercase ident (sibling constructor pattern)
                    if self.peek().type == TokenType.IDENT and self.peek().value[0].isupper():
                        break
                    args.append(self.parse_pattern())
                return PatConstructor(name, args)
            return PatIdent(name)

        raise ParseError(f"Unexpected token in pattern: {token.type.name}", token)


def parse(tokens: List[Token]) -> Program:
    return Parser(tokens).parse_program()
