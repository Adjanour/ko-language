"""Kō Lexer - Tokenizer for the Kō language"""

from dataclasses import dataclass
from enum import Enum, auto
from typing import List


class TokenType(Enum):
    # Literals
    INT = auto()
    FLOAT = auto()
    STRING = auto()
    CHAR = auto()
    TRUE = auto()
    FALSE = auto()

    # Identifiers
    IDENT = auto()

    # Keywords
    FN = auto()
    TYPE = auto()
    LET = auto()
    MATCH = auto()
    IF = auto()
    THEN = auto()
    ELSE = auto()
    PANIC = auto()
    INSPECT = auto()
    PRINTLN = auto()

    # Operators
    PLUS = auto()       # +
    MINUS = auto()      # -
    STAR = auto()       # *
    SLASH = auto()      # /
    PERCENT = auto()    # %
    EQ = auto()         # ==
    NEQ = auto()        # !=
    LT = auto()         # <
    GT = auto()         # >
    LTE = auto()        # <=
    GTE = auto()        # >=
    AND = auto()        # &&
    OR = auto()         # ||
    NOT = auto()        # !
    ASSIGN = auto()     # =
    ARROW = auto()      # ->

    # Delimiters
    LPAREN = auto()     # (
    RPAREN = auto()     # )
    PIPE = auto()       # |
    UNDERSCORE = auto() # _
    WILDCARD = auto()   # * (in type context)

    # Special
    NEWLINE = auto()
    EOF = auto()


KEYWORDS = {
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
}


@dataclass
class Token:
    type: TokenType
    value: str
    line: int
    col: int

    def __repr__(self):
        return f"Token({self.type.name}, {self.value!r}, {self.line}:{self.col})"


class LexerError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"Lexer error at {line}:{col}: {msg}")
        self.line = line
        self.col = col


class Lexer:
    def __init__(self, source: str):
        self.source = source
        self.pos = 0
        self.line = 1
        self.col = 1
        self.tokens: List[Token] = []

    def peek(self) -> str:
        if self.pos < len(self.source):
            return self.source[self.pos]
        return '\0'

    def advance(self) -> str:
        ch = self.source[self.pos]
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.col = 1
        else:
            self.col += 1
        return ch

    def skip_whitespace(self):
        while self.pos < len(self.source) and self.source[self.pos] in ' \t\r':
            self.advance()

    def skip_comment(self):
        if self.peek() == '#':
            while self.pos < len(self.source) and self.peek() != '\n':
                self.advance()
        elif self.peek() == '/' and self.pos + 1 < len(self.source):
            if self.source[self.pos + 1] == '/':
                # Single-line comment //
                self.advance()
                self.advance()
                while self.pos < len(self.source) and self.peek() != '\n':
                    self.advance()
            elif self.source[self.pos + 1] == '*':
                # Multi-line comment /* */
                self.advance()
                self.advance()
                while self.pos < len(self.source):
                    if self.peek() == '*' and self.pos + 1 < len(self.source) and self.source[self.pos + 1] == '/':
                        self.advance()
                        self.advance()
                        return
                    self.advance()

    def read_string(self) -> Token:
        start_line, start_col = self.line, self.col
        self.advance()  # skip opening "
        result = []
        while self.peek() != '"' and self.peek() != '\0':
            if self.peek() == '\\':
                self.advance()
                ch = self.advance()
                if ch == 'n': result.append('\n')
                elif ch == 't': result.append('\t')
                elif ch == '\\': result.append('\\')
                elif ch == '"': result.append('"')
                else: result.append(ch)
            else:
                result.append(self.advance())
        if self.peek() == '\0':
            raise LexerError("Unterminated string", start_line, start_col)
        self.advance()  # skip closing "
        return Token(TokenType.STRING, ''.join(result), start_line, start_col)

    def read_char(self) -> Token:
        start_line, start_col = self.line, self.col
        self.advance()  # skip opening '
        if self.peek() == '\\':
            self.advance()
            ch = self.advance()
            if ch == 'n': val = '\n'
            elif ch == 't': val = '\t'
            elif ch == '\\': val = '\\'
            elif ch == "'": val = "'"
            else: val = ch
        else:
            val = self.advance()
        if self.peek() != "'":
            raise LexerError("Unterminated char", start_line, start_col)
        self.advance()  # skip closing '
        return Token(TokenType.CHAR, val, start_line, start_col)

    def read_number(self) -> Token:
        start_line, start_col = self.line, self.col
        result = []
        has_dot = False
        is_hex = False

        # Check for hex prefix
        if self.peek() == '0' and self.pos + 1 < len(self.source) and self.source[self.pos + 1] in 'xX':
            is_hex = True
            result.append(self.advance())  # '0'
            result.append(self.advance())  # 'x' or 'X'
            # Read hex digits and underscores
            while self.peek().isdigit() or self.peek() in 'abcdefABCDEF_':
                result.append(self.advance())
        else:
            # Read decimal digits, underscores, and optional dot
            while self.peek().isdigit() or self.peek() == '_' or self.peek() == '.':
                if self.peek() == '.':
                    if has_dot:
                        break
                    has_dot = True
                result.append(self.advance())

        value = ''.join(result)
        if has_dot:
            return Token(TokenType.FLOAT, value, start_line, start_col)
        return Token(TokenType.INT, value, start_line, start_col)

    def read_ident(self) -> Token:
        start_line, start_col = self.line, self.col
        result = []
        while self.peek().isalnum() or self.peek() in '_-':
            result.append(self.advance())
        value = ''.join(result)
        token_type = KEYWORDS.get(value, TokenType.IDENT)
        return Token(token_type, value, start_line, start_col)

    def tokenize(self) -> List[Token]:
        while self.pos < len(self.source):
            self.skip_whitespace()
            self.skip_comment()

            if self.pos >= len(self.source):
                break

            ch = self.peek()

            # Newlines
            if ch == '\n':
                self.tokens.append(Token(TokenType.NEWLINE, '\\n', self.line, self.col))
                self.advance()
                continue

            # Strings
            if ch == '"':
                self.tokens.append(self.read_string())
                continue

            # Chars
            if ch == "'":
                self.tokens.append(self.read_char())
                continue

            # Numbers
            if ch.isdigit():
                self.tokens.append(self.read_number())
                continue

            # Underscore (wildcard)
            if ch == '_':
                start_line, start_col = self.line, self.col
                self.advance()
                # Check if it's a standalone underscore or start of identifier
                if not self.peek().isalnum() and self.peek() != '_' and self.peek() != '-':
                    self.tokens.append(Token(TokenType.UNDERSCORE, '_', start_line, start_col))
                    continue
                # It's an identifier starting with _
                result = ['_']
                while self.peek().isalnum() or self.peek() in '_-':
                    result.append(self.advance())
                value = ''.join(result)
                self.tokens.append(Token(TokenType.IDENT, value, start_line, start_col))
                continue

            # Identifiers and keywords
            if ch.isalpha() or ch == '_':
                self.tokens.append(self.read_ident())
                continue

            # Operators and delimiters
            start_line, start_col = self.line, self.col
            self.advance()

            if ch == '+':
                self.tokens.append(Token(TokenType.PLUS, '+', start_line, start_col))
            elif ch == '-':
                if self.peek() == '>':
                    self.advance()
                    self.tokens.append(Token(TokenType.ARROW, '->', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.MINUS, '-', start_line, start_col))
            elif ch == '*':
                self.tokens.append(Token(TokenType.STAR, '*', start_line, start_col))
            elif ch == '/':
                self.tokens.append(Token(TokenType.SLASH, '/', start_line, start_col))
            elif ch == '%':
                self.tokens.append(Token(TokenType.PERCENT, '%', start_line, start_col))
            elif ch == '=':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.EQ, '==', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.ASSIGN, '=', start_line, start_col))
            elif ch == '!':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.NEQ, '!=', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.NOT, '!', start_line, start_col))
            elif ch == '<':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.LTE, '<=', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.LT, '<', start_line, start_col))
            elif ch == '>':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.GTE, '>=', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.GT, '>', start_line, start_col))
            elif ch == '&':
                if self.peek() == '&':
                    self.advance()
                    self.tokens.append(Token(TokenType.AND, '&&', start_line, start_col))
                else:
                    raise LexerError("Expected &&", start_line, start_col)
            elif ch == '|':
                if self.peek() == '|':
                    self.advance()
                    self.tokens.append(Token(TokenType.OR, '||', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.PIPE, '|', start_line, start_col))
            elif ch == '(':
                self.tokens.append(Token(TokenType.LPAREN, '(', start_line, start_col))
            elif ch == ')':
                self.tokens.append(Token(TokenType.RPAREN, ')', start_line, start_col))
            elif ch == '_':
                self.tokens.append(Token(TokenType.UNDERSCORE, '_', start_line, start_col))
            else:
                raise LexerError(f"Unexpected character: {ch}", start_line, start_col)

        self.tokens.append(Token(TokenType.EOF, '', self.line, self.col))
        return self.tokens


def tokenize(source: str) -> List[Token]:
    return Lexer(source).tokenize()


if __name__ == '__main__':
    import sys
    source = sys.stdin.read()
    tokens = tokenize(source)
    for t in tokens:
        print(t)
