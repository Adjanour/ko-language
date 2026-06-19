"""Kō Lexer — Tokenizer for the Kō language.

Design principles (from Rust, Go, Zig):
- Hand-written state machine (Zig-style)
- Token stores byte offsets, not strings (Zig-style)
- Null-terminated source for efficient scanning (Zig-style)
- Error accumulation (Rust-style)
- Clean separation from parser
"""

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import List, Optional


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
    IMPORT = auto()
    AS = auto()
    REF = auto()
    COMPILETIME = auto()

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
    BANG = auto()       # ! (deref)
    ASSIGN = auto()     # =
    ARROW = auto()      # ->
    BACKSLASH = auto()  # \ (lambda)
    DOLLAR_LBRACE = auto()  # ${ (string interpolation)
    RBRACE = auto()     # } (interpolation closing)
    COLON_EQ = auto()   # := (set ref)
    COLON_COLON = auto()  # :: (cons)

    # Delimiters
    LPAREN = auto()     # (
    RPAREN = auto()     # )
    PIPE = auto()       # |
    PIPE_GT = auto()    # |> (pipe)
    UNDERSCORE = auto() # _
    LBRACKET = auto()   # [
    RBRACKET = auto()   # ]
    COMMA = auto()      # ,
    COLON = auto()      # :

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
    'import': TokenType.IMPORT,
    'as': TokenType.AS,
    'ref': TokenType.REF,
    'comptime': TokenType.COMPILETIME,
}


class Token:
    """A single token from the source.

    Stores byte offsets (start, end) into the source string.
    Use lexer.token_value(token) to get the lexeme text.
    """

    __slots__ = ('type', 'start', 'end', 'line', 'col', '_source')

    def __init__(self, type: TokenType, start: int, end: int, line: int, col: int, source: str = ''):
        self.type = type
        self.start = start
        self.end = end
        self.line = line
        self.col = col
        self._source = source

    @property
    def value(self) -> str:
        """Get the lexeme text. Works if source was provided."""
        return self._source[self.start:self.end]

    def __repr__(self):
        return f"Token({self.type.name}, {self.start}:{self.end}, {self.line}:{self.col})"


class LexerError(Exception):
    def __init__(self, msg: str, line: int, col: int):
        super().__init__(f"Lexer error at {line}:{col}: {msg}")
        self.msg = msg
        self.line = line
        self.col = col


class Lexer:
    """Hand-written recursive descent lexer for Kō.

    Design:
    - Source is null-terminated for efficient scanning
    - Token stores byte offsets (start, end) into source
    - State machine in tokenize() dispatches on current character
    - Errors are accumulated, not raised immediately
    """

    def __init__(self, source: str, file: str = "<input>"):
        self.source = source + '\0'  # null sentinel (Zig trick)
        self.file = file
        self.pos = 0
        self.line = 1
        self.col = 1
        self.tokens: List[Token] = []
        self.errors: List[LexerError] = []
        self.in_interpolation = False

    def peek(self) -> str:
        return self.source[self.pos]

    def peek_next(self) -> str:
        return self.source[self.pos + 1]

    def advance(self) -> str:
        ch = self.source[self.pos]
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.col = 1
        else:
            self.col += 1
        return ch

    def make_token(self, ttype: TokenType, start: int) -> Token:
        """Create a token from start to current position."""
        return Token(ttype, start, self.pos, self.line, self.col - (self.pos - start), self.source)

    def skip_whitespace(self):
        while self.peek() in ' \t\r':
            self.advance()

    def skip_comment(self) -> bool:
        """Skip a comment if one is found. Returns True if a comment was skipped."""
        if self.peek() == '#':
            if self.peek_next() == '|' and self.pos + 2 < len(self.source):
                # Block comment #| ... |#
                self.advance()  # #
                self.advance()  # |
                while self.peek() != '\0':
                    if self.peek() == '|' and self.peek_next() == '#':
                        self.advance()  # |
                        self.advance()  # #
                        return True
                    self.advance()
                raise LexerError("Unterminated block comment", self.line, self.col)
            else:
                # Line comment # ...
                while self.peek() != '\n' and self.peek() != '\0':
                    self.advance()
                return True

        elif self.peek() == '/' and self.peek_next() == '/':
            # Line comment // ...
            self.advance()  # /
            self.advance()  # /
            while self.peek() != '\n' and self.peek() != '\0':
                self.advance()
            return True

        elif self.peek() == '/' and self.peek_next() == '*':
            # Block comment /* ... */
            self.advance()  # /
            self.advance()  # *
            while self.peek() != '\0':
                if self.peek() == '*' and self.peek_next() == '/':
                    self.advance()  # *
                    self.advance()  # /
                    return True
                self.advance()
            raise LexerError("Unterminated block comment", self.line, self.col)

        return False

    def read_string(self, is_continuation: bool = False) -> List[Token]:
        """Read a string, handling interpolation and escapes.

        Returns a list of tokens:
        - STRING for literal content
        - DOLLAR_LBRACE for ${
        - The parser handles everything between DOLLAR_LBRACE and RBRACE

        For interpolation, the string is split into multiple STRING tokens
        separated by DOLLAR_LBRACE tokens.
        """
        tokens = []
        start_line, start_col = self.line, self.col

        if not is_continuation:
            self.advance()  # skip opening "

        content_start = self.pos
        while self.peek() != '"' and self.peek() != '\0' and self.peek() != '\n':
            if self.peek() == '\\':
                self.advance()  # skip backslash
                if self.peek() != '\0':
                    self.advance()  # skip escaped char
            elif self.peek() == '$' and self.peek_next() == '{':
                # Emit string content so far
                if self.pos > content_start:
                    tokens.append(Token(TokenType.STRING, content_start, self.pos, start_line, start_col, self.source))
                # Emit DOLLAR_LBRACE
                dollar_start = self.pos
                self.advance()  # $
                self.advance()  # {
                tokens.append(Token(TokenType.DOLLAR_LBRACE, dollar_start, self.pos, start_line, start_col, self.source))
                self.in_interpolation = True
                return tokens
            else:
                self.advance()

        if self.peek() == '\0' or self.peek() == '\n':
            raise LexerError("Unterminated string", start_line, start_col)

        # Emit final string content
        if self.pos > content_start or not tokens:
            tokens.append(Token(TokenType.STRING, content_start, self.pos, start_line, start_col, self.source))

        self.advance()  # skip closing "
        return tokens

    def read_char(self) -> Token:
        start = self.pos
        start_line, start_col = self.line, self.col
        self.advance()  # skip opening '

        if self.peek() == '\\':
            self.advance()  # skip backslash
            if self.peek() != '\0':
                self.advance()  # skip escaped char
        else:
            if self.peek() != '\0':
                self.advance()  # skip the character

        if self.peek() != "'":
            raise LexerError("Unterminated char", start_line, start_col)

        self.advance()  # skip closing '
        return Token(TokenType.CHAR, start, self.pos, start_line, start_col, self.source)

    def read_number(self) -> Token:
        start = self.pos
        start_line, start_col = self.line, self.col

        if self.peek() == '0' and self.peek_next() in 'xX':
            # Hex: 0xFF
            self.advance()  # 0
            self.advance()  # x/X
            while self.peek().isalnum() or self.peek() == '_':
                self.advance()
        elif self.peek() == '0' and self.peek_next() in 'bB':
            # Binary: 0b1010
            self.advance()  # 0
            self.advance()  # b/B
            while self.peek() in '01_':
                self.advance()
        else:
            # Decimal (possibly float)
            while self.peek().isdigit() or self.peek() == '_':
                self.advance()
            if self.peek() == '.' and self.peek_next().isdigit():
                # Float
                self.advance()  # .
                while self.peek().isdigit() or self.peek() == '_':
                    self.advance()

        ttype = TokenType.FLOAT if '.' in self.source[start:self.pos] else TokenType.INT
        return Token(ttype, start, self.pos, start_line, start_col, self.source)

    def read_ident(self) -> Token:
        start = self.pos
        start_line, start_col = self.line, self.col

        while self.peek().isalnum() or self.peek() in '_-':
            self.advance()

        value = self.source[start:self.pos]
        ttype = KEYWORDS.get(value, TokenType.IDENT)
        return Token(ttype, start, self.pos, start_line, start_col, self.source)

    def tokenize(self) -> List[Token]:
        """Main tokenization loop.

        State machine dispatches on current character.
        Returns list of tokens ending with EOF.
        """
        while self.peek() != '\0':
            # Skip whitespace (spaces, tabs, carriage returns)
            self.skip_whitespace()

            # Skip comments (returns True if a comment was skipped)
            if self.skip_comment():
                continue

            # Skip whitespace again after comments
            self.skip_whitespace()

            # Check for end of input
            if self.peek() == '\0':
                break

            ch = self.peek()
            start = self.pos
            start_line, start_col = self.line, self.col

            # Newlines
            if ch == '\n':
                self.tokens.append(Token(TokenType.NEWLINE, start, start + 1, self.line, self.col, self.source))
                self.advance()
                continue

            # Strings
            if ch == '"':
                self.tokens.extend(self.read_string())
                continue

            # Chars
            if ch == "'":
                self.tokens.append(self.read_char())
                continue

            # Numbers
            if ch.isdigit():
                self.tokens.append(self.read_number())
                continue

            # Identifiers and keywords
            if ch.isalpha() or ch == '_':
                # Check if it's a standalone underscore
                if ch == '_':
                    # Look ahead: if next char is not alphanumeric/underscore, it's UNDERSCORE
                    next_ch = self.peek_next()
                    if not (next_ch.isalnum() or next_ch == '_' or next_ch == '-'):
                        self.advance()
                        self.tokens.append(Token(TokenType.UNDERSCORE, start, self.pos, start_line, start_col, self.source))
                        continue
                self.tokens.append(self.read_ident())
                continue

            # Single-character tokens and multi-character operators
            self.advance()

            if ch == '+':
                self.tokens.append(Token(TokenType.PLUS, start, self.pos, start_line, start_col, self.source))
            elif ch == '-':
                if self.peek() == '>':
                    self.advance()
                    self.tokens.append(Token(TokenType.ARROW, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.MINUS, start, self.pos, start_line, start_col, self.source))
            elif ch == '*':
                self.tokens.append(Token(TokenType.STAR, start, self.pos, start_line, start_col, self.source))
            elif ch == '/':
                self.tokens.append(Token(TokenType.SLASH, start, self.pos, start_line, start_col, self.source))
            elif ch == '%':
                self.tokens.append(Token(TokenType.PERCENT, start, self.pos, start_line, start_col, self.source))
            elif ch == '=':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.EQ, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.ASSIGN, start, self.pos, start_line, start_col, self.source))
            elif ch == '!':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.NEQ, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.BANG, start, self.pos, start_line, start_col, self.source))
            elif ch == ':':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.COLON_EQ, start, self.pos, start_line, start_col, self.source))
                elif self.peek() == ':':
                    self.advance()
                    self.tokens.append(Token(TokenType.COLON_COLON, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.COLON, start, self.pos, start_line, start_col, self.source))
            elif ch == '<':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.LTE, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.LT, start, self.pos, start_line, start_col, self.source))
            elif ch == '>':
                if self.peek() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.GTE, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.GT, start, self.pos, start_line, start_col, self.source))
            elif ch == '&':
                if self.peek() == '&':
                    self.advance()
                    self.tokens.append(Token(TokenType.AND, start, self.pos, start_line, start_col, self.source))
                else:
                    raise LexerError("Expected &&", start_line, start_col)
            elif ch == '|':
                if self.peek() == '|':
                    self.advance()
                    self.tokens.append(Token(TokenType.OR, start, self.pos, start_line, start_col, self.source))
                elif self.peek() == '>':
                    self.advance()
                    self.tokens.append(Token(TokenType.PIPE_GT, start, self.pos, start_line, start_col, self.source))
                else:
                    self.tokens.append(Token(TokenType.PIPE, start, self.pos, start_line, start_col, self.source))
            elif ch == '(':
                self.tokens.append(Token(TokenType.LPAREN, start, self.pos, start_line, start_col, self.source))
            elif ch == ')':
                self.tokens.append(Token(TokenType.RPAREN, start, self.pos, start_line, start_col, self.source))
            elif ch == '[':
                self.tokens.append(Token(TokenType.LBRACKET, start, self.pos, start_line, start_col, self.source))
            elif ch == ']':
                self.tokens.append(Token(TokenType.RBRACKET, start, self.pos, start_line, start_col, self.source))
            elif ch == '}':
                if self.in_interpolation:
                    self.tokens.append(Token(TokenType.RBRACE, start, self.pos, start_line, start_col, self.source))
                    self.in_interpolation = False
                    # Continue reading the rest of the string
                    self.tokens.extend(self.read_string(is_continuation=True))
                else:
                    self.tokens.append(Token(TokenType.RBRACE, start, self.pos, start_line, start_col, self.source))
            elif ch == ',':
                self.tokens.append(Token(TokenType.COMMA, start, self.pos, start_line, start_col, self.source))
            elif ch == '\\':
                self.tokens.append(Token(TokenType.BACKSLASH, start, self.pos, start_line, start_col, self.source))
            else:
                raise LexerError(f"Unexpected character: {ch}", start_line, start_col)

        self.tokens.append(Token(TokenType.EOF, self.pos, self.pos, self.line, self.col, self.source))
        return self.tokens


def tokenize(source: str, file: str = "<input>") -> List[Token]:
    """Tokenize a Kō source string. Returns list of tokens ending with EOF."""
    return Lexer(source, file).tokenize()


if __name__ == '__main__':
    import sys
    source = sys.stdin.read()
    tokens = tokenize(source)
    for t in tokens:
        print(t)
