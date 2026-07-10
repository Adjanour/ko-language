const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const Tag = enum {
        // Special
        invalid,
        eof,
        newline,
        indent,
        dedent,

        // Literals
        number,
        string,
        char,
        identifier,
        constructor,

        // Keywords
        keyword_fn,
        keyword_let,
        keyword_if,
        keyword_then,
        keyword_else,
        keyword_match,
        keyword_type,
        keyword_import,
        keyword_package,
        keyword_pub,
        keyword_module,
        keyword_comptime,
        keyword_true,
        keyword_false,
        keyword_as,
        keyword_and,
        keyword_or,
        keyword_not,
        keyword_ref,

        // Operators
        plus,
        minus,
        star,
        slash,
        percent,
        equal,
        equal_equal,
        not_equal,
        less_than,
        less_equal,
        greater_than,
        greater_equal,
        and_and,
        or_or,
        not,
        ampersand,
        pipe,
        pipe_gt,
        fat_arrow,
        arrow,
        backslash,
        tilde,
        question,

        // Delimiters
        lparen,
        rparen,
        lbrace,
        rbrace,
        lbracket,
        rbracket,
        comma,
        colon,
        colon_equal,
        double_colon,
        semicolon,
        dot,
        underscore,

        // Comments
        comment,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .eof,
                .newline,
                .indent,
                .dedent,
                .number,
                .string,
                .char,
                .identifier,
                .constructor,
                .comment,
                => null,

                .keyword_fn => "fn",
                .keyword_let => "let",
                .keyword_if => "if",
                .keyword_then => "then",
                .keyword_else => "else",
                .keyword_match => "match",
                .keyword_type => "type",
                .keyword_import => "import",
                .keyword_package => "package",
                .keyword_pub => "pub",
                .keyword_module => "module",
                .keyword_comptime => "comptime",
                .keyword_true => "true",
                .keyword_false => "false",
                .keyword_as => "as",
                .keyword_and => "and",
                .keyword_or => "or",
                .keyword_not => "not",
                .keyword_ref => "ref",

                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .percent => "%",
                .equal => "=",
                .equal_equal => "==",
                .not_equal => "!=",
                .less_than => "<",
                .less_equal => "<=",
                .greater_than => ">",
                .greater_equal => ">=",
                .and_and => "&&",
                .or_or => "||",
                .not => "!",
                .ampersand => "&",
                .pipe => "|",
                .pipe_gt => "|>",
                .fat_arrow => "=>",
                .arrow => "->",
                .backslash => "\\",
                .tilde => "~",
                .question => "?",

                .lparen => "(",
                .rparen => ")",
                .lbrace => "{",
                .rbrace => "}",
                .lbracket => "[",
                .rbracket => "]",
                .comma => ",",
                .colon => ":",
                .colon_equal => ":=",
                .double_colon => "::",
                .semicolon => ";",
                .dot => ".",
                .underscore => "_",
            };
        }

        pub fn humanName(tag: Tag) []const u8 {
            return switch (tag) {
                .invalid => "invalid token",
                .eof => "end of file",
                .newline => "newline",
                .indent => "indent",
                .dedent => "dedent",
                .number => "number",
                .string => "string",
                .char => "char",
                .identifier => "identifier",
                .constructor => "constructor",
                .comment => "comment",

                .keyword_fn => "'fn'",
                .keyword_let => "'let'",
                .keyword_if => "'if'",
                .keyword_then => "'then'",
                .keyword_else => "'else'",
                .keyword_match => "'match'",
                .keyword_type => "'type'",
                .keyword_import => "'import'",
                .keyword_package => "'package'",
                .keyword_pub => "'pub'",
                .keyword_module => "'module'",
                .keyword_comptime => "'comptime'",
                .keyword_true => "'true'",
                .keyword_false => "'false'",
                .keyword_as => "'as'",
                .keyword_and => "'and'",
                .keyword_or => "'or'",
                .keyword_not => "'not'",
                .keyword_ref => "'ref'",

                .plus => "'+'",
                .minus => "'-'",
                .star => "'*'",
                .slash => "'/'",
                .percent => "'%'",
                .equal => "'='",
                .equal_equal => "'=='",
                .not_equal => "'!='",
                .less_than => "'<'",
                .less_equal => "'<='",
                .greater_than => "'>'",
                .greater_equal => "'>='",
                .and_and => "'&&'",
                .or_or => "'||'",
                .not => "'!'",
                .ampersand => "'&'",
                .pipe => "'|'",
                .pipe_gt => "'|>'",
                .fat_arrow => "'=>'",
                .arrow => "'->'",
                .backslash => "'\\'",
                .tilde => "'~'",
                .question => "'?'",

                .lparen => "'('",
                .rparen => "')'",
                .lbrace => "'{'",
                .rbrace => "'}'",
                .lbracket => "'['",
                .rbracket => "']'",
                .comma => "','",
                .colon => "':'",
                .colon_equal => "':='",
                .double_colon => "'::'",
                .semicolon => "';'",
                .dot => "'.'",
                .underscore => "'_'",
            };
        }
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .keyword_fn },
        .{ "let", .keyword_let },
        .{ "if", .keyword_if },
        .{ "then", .keyword_then },
        .{ "else", .keyword_else },
        .{ "match", .keyword_match },
        .{ "type", .keyword_type },
        .{ "import", .keyword_import },
        .{ "package", .keyword_package },
        .{ "pub", .keyword_pub },
        .{ "module", .keyword_module },
        .{ "comptime", .keyword_comptime },
        .{ "true", .keyword_true },
        .{ "false", .keyword_false },
        .{ "as", .keyword_as },
        .{ "and", .keyword_and },
        .{ "or", .keyword_or },
        .{ "not", .keyword_not },
        .{ "ref", .keyword_ref },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }
};

const State = enum {
    start,
    identifier,
    number,
    number_hex,
    number_binary,
    number_octal,
    float,
    float_exponent,
    string,
    string_backslash,
    char,
    char_backslash,
    comment,
    equal,
    bang,
    less_than,
    greater_than,
    pipe,
    minus,
    plus,
    star,
    slash,
    percent,
    invalid,
};

pub const Tokenizer = struct {
    source: [:0]const u8,
    index: usize,
    indent_stack: [64]u32,
    indent_pos: usize,
    pending_newline: bool,
    pending_dedents: usize,
    pending_comments: [4]?[]const u8,
    pending_comment_count: u8,

    pub fn init(source: [:0]const u8) Tokenizer {
        return .{
            .source = source,
            // Skip UTF-8 BOM if present
            .index = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0,
            .indent_stack = std.mem.zeroes([64]u32),
            .indent_pos = 0,
            .pending_newline = false,
            .pending_dedents = 0,
            .pending_comments = std.mem.zeroes([4]?[]const u8),
            .pending_comment_count = 0,
        };
    }

    fn pushComment(self: *Tokenizer, text: []const u8) void {
        if (self.pending_comment_count < 4) {
            self.pending_comments[self.pending_comment_count] = text;
            self.pending_comment_count += 1;
        }
    }

    pub fn next(self: *Tokenizer) Token {
        if (self.pending_comment_count > 0) {
            const text = self.pending_comments[0].?;
            var i: u8 = 0;
            while (i + 1 < self.pending_comment_count) : (i += 1) {
                self.pending_comments[i] = self.pending_comments[i + 1];
            }
            self.pending_comments[self.pending_comment_count - 1] = null;
            self.pending_comment_count -= 1;
            return .{ .tag = .comment, .loc = .{ .start = @intCast(@intFromPtr(text.ptr) - @intFromPtr(self.source.ptr)), .end = @intCast(@intFromPtr(text.ptr) - @intFromPtr(self.source.ptr) + text.len) } };
        }
        if (self.pending_dedents > 0) {
            self.pending_dedents -= 1;
            return .{ .tag = .dedent, .loc = .{ .start = self.index, .end = self.index } };
        }

        // Handle pending newline/indent/dedent tokens
        if (self.pending_newline) {
            self.pending_newline = false;
            return self.scan_indent();
        }

        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };

        state: switch (State.start) {
            .start => switch (self.source[self.index]) {
                0 => {
                    if (self.index == self.source.len) {
                        // Emit dedents at EOF
                        if (self.indent_pos > 0) {
                            self.indent_pos -= 1;
                            result.tag = .dedent;
                            result.loc.end = self.index;
                            return result;
                        }
                        return .{ .tag = .eof, .loc = .{ .start = self.index, .end = self.index } };
                    }
                    continue :state .invalid;
                },
                ' ', '\t' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '\n', '\r' => {
                    self.index += 1;
                    if (self.source[self.index] == '\n') self.index += 1;
                    result.tag = .newline;
                    result.loc.end = self.index;
                    self.pending_newline = true;
                    return result;
                },
                'a'...'z' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                'A'...'Z' => {
                    result.tag = .constructor;
                    continue :state .identifier;
                },
                '_' => {
                    const next_ch = self.source[self.index + 1];
                    if (next_ch == '_' or std.ascii.isAlphanumeric(next_ch) or next_ch == '-') {
                        result.tag = .identifier;
                        continue :state .identifier;
                    }
                    result.tag = .underscore;
                    self.index += 1;
                },
                '0'...'9' => {
                    result.tag = .number;
                    self.index += 1;
                    continue :state .number;
                },
                '"' => {
                    result.tag = .string;
                    continue :state .string;
                },
                '\'' => {
                    result.tag = .char;
                    continue :state .char;
                },
                '#' => continue :state .comment,
                '\\' => {
                    result.tag = .backslash;
                    self.index += 1;
                },

                // Single-char tokens
                '(' => {
                    result.tag = .lparen;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .rparen;
                    self.index += 1;
                },
                '{' => {
                    result.tag = .lbrace;
                    self.index += 1;
                },
                '}' => {
                    result.tag = .rbrace;
                    self.index += 1;
                },
                '[' => {
                    result.tag = .lbracket;
                    self.index += 1;
                },
                ']' => {
                    result.tag = .rbracket;
                    self.index += 1;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;
                },
                ':' => {
                    self.index += 1;
                    if (self.source[self.index] == '=') {
                        result.tag = .colon_equal;
                        self.index += 1;
                    } else if (self.source[self.index] == ':') {
                        result.tag = .double_colon;
                        self.index += 1;
                    } else {
                        result.tag = .colon;
                    }
                },
                ';' => {
                    result.tag = .semicolon;
                    self.index += 1;
                },
                '.' => {
                    result.tag = .dot;
                    self.index += 1;
                },
                '~' => {
                    result.tag = .tilde;
                    self.index += 1;
                },
                '?' => {
                    result.tag = .question;
                    self.index += 1;
                },

                // Multi-char operators
                '=' => continue :state .equal,
                '!' => continue :state .bang,
                '<' => continue :state .less_than,
                '>' => continue :state .greater_than,
                '|' => continue :state .pipe,
                '&' => {
                    if (self.source[self.index + 1] == '&') {
                        result.tag = .and_and;
                        self.index += 2;
                    } else {
                        result.tag = .ampersand;
                        self.index += 1;
                    }
                },
                '-' => continue :state .minus,
                '+' => continue :state .plus,
                '*' => continue :state .star,
                '/' => continue :state .slash,
                '%' => continue :state .percent,

                else => continue :state .invalid,
            },

            .identifier => {
                self.index += 1;
                switch (self.source[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    '-' => continue :state .identifier,
                    else => {
                        const ident = self.source[result.loc.start..self.index];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .number => {
                switch (self.source[self.index]) {
                    'x', 'X' => {
                        self.index += 1;
                        continue :state .number_hex;
                    },
                    'b', 'B' => {
                        self.index += 1;
                        continue :state .number_binary;
                    },
                    'o', 'O' => {
                        self.index += 1;
                        continue :state .number_octal;
                    },
                    '0'...'9', '_' => {
                        self.index += 1;
                        continue :state .number;
                    },
                    '.' => {
                        // Check if next char is digit (float) or not (dot operator)
                        if (self.source[self.index + 1] >= '0' and self.source[self.index + 1] <= '9') {
                            self.index += 1;
                            continue :state .float;
                        }
                    },
                    'e', 'E' => {
                        self.index += 1;
                        continue :state .float_exponent;
                    },
                    else => {},
                }
            },

            .number_hex => {
                switch (self.source[self.index]) {
                    '0'...'9', 'a'...'f', 'A'...'F', '_' => {
                        self.index += 1;
                        continue :state .number_hex;
                    },
                    else => {},
                }
            },

            .number_binary => {
                switch (self.source[self.index]) {
                    '0', '1', '_' => {
                        self.index += 1;
                        continue :state .number_binary;
                    },
                    else => {},
                }
            },

            .number_octal => {
                switch (self.source[self.index]) {
                    '0'...'7', '_' => {
                        self.index += 1;
                        continue :state .number_octal;
                    },
                    else => {},
                }
            },

            .float => {
                switch (self.source[self.index]) {
                    '0'...'9', '_' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    'e', 'E' => {
                        self.index += 1;
                        continue :state .float_exponent;
                    },
                    else => {},
                }
            },

            .float_exponent => {
                switch (self.source[self.index]) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .float,
                }
            },

            .string => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    '\\' => continue :state .string_backslash,
                    '"' => self.index += 1,
                    else => continue :state .string,
                }
            },

            .string_backslash => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    else => continue :state .string,
                }
            },

            .comment => {
                const start = self.index + 1;
                while (self.index < self.source.len) : (self.index += 1) {
                    switch (self.source[self.index]) {
                        0, '\n' => {
                            self.pushComment(self.source[start..self.index]);
                            if (self.source[self.index] == '\n') self.index += 1;
                            return self.scan_indent();
                        },
                        else => {},
                    }
                }
                self.pushComment(self.source[start..self.source.len]);
            },

            .equal => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        result.tag = .equal_equal;
                        self.index += 1;
                    },
                    '>' => {
                        result.tag = .fat_arrow;
                        self.index += 1;
                    },
                    else => result.tag = .equal,
                }
            },

            .bang => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        result.tag = .not_equal;
                        self.index += 1;
                    },
                    else => result.tag = .not,
                }
            },

            .less_than => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        result.tag = .less_equal;
                        self.index += 1;
                    },
                    else => result.tag = .less_than,
                }
            },

            .greater_than => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '=' => {
                        result.tag = .greater_equal;
                        self.index += 1;
                    },
                    else => result.tag = .greater_than,
                }
            },

            .pipe => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '|' => {
                        result.tag = .or_or;
                        self.index += 1;
                    },
                    '>' => {
                        result.tag = .pipe_gt;
                        self.index += 1;
                    },
                    else => result.tag = .pipe,
                }
            },

            .minus => {
                self.index += 1;
                switch (self.source[self.index]) {
                    '>' => {
                        result.tag = .arrow;
                        self.index += 1;
                    },
                    else => result.tag = .minus,
                }
            },

            .plus => {
                self.index += 1;
                result.tag = .plus;
            },

            .star => {
                self.index += 1;
                result.tag = .star;
            },

            .slash => {
                self.index += 1;
                result.tag = .slash;
            },

            .percent => {
                self.index += 1;
                result.tag = .percent;
            },

            .char => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    '\\' => continue :state .char_backslash,
                    '\'' => self.index += 1,
                    0x01...0x09, 0x0b...0x1f, 0x7f => continue :state .invalid,
                    else => continue :state .char,
                }
            },

            .char_backslash => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    else => continue :state .char,
                }
            },

            .invalid => {
                self.index += 1;
                switch (self.source[self.index]) {
                    0 => if (self.index == self.source.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n', '\r' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },
        }

        result.loc.end = self.index;
        return result;
    }

    fn scan_indent(self: *Tokenizer) Token {
        const start = self.index;

        while (true) {
            var col: u32 = 0;

            // Count spaces/tabs at start of line.
            while (true) {
                switch (self.source[self.index]) {
                    ' ' => {
                        col += 1;
                        self.index += 1;
                    },
                    '\t' => {
                        col += 4; // Tab = 4 spaces
                        self.index += 1;
                    },
                    '#' => {
                        // Comment-only line: store comment and skip to end of line.
                        const cstart = self.index + 1;
                        while (self.source[self.index] != 0 and self.source[self.index] != '\n') {
                            self.index += 1;
                        }
                        self.pushComment(self.source[cstart..self.index]);
                        if (self.source[self.index] == '\n') self.index += 1;
                        break;
                    },
                    '\r' => {
                        self.index += 1;
                        if (self.source[self.index] == '\n') self.index += 1;
                        break;
                    },
                    '\n' => {
                        self.index += 1;
                        break;
                    },
                    else => {
                        const current_indent = if (self.indent_pos > 0) self.indent_stack[self.indent_pos - 1] else 0;

                        if (col > current_indent) {
                            if (self.indent_pos < 64) {
                                self.indent_stack[self.indent_pos] = col;
                                self.indent_pos += 1;
                            }
                            return .{ .tag = .indent, .loc = .{ .start = start, .end = self.index } };
                        }

                        if (col < current_indent) {
                            while (self.indent_pos > 0 and self.indent_stack[self.indent_pos - 1] > col) {
                                self.indent_pos -= 1;
                                self.pending_dedents += 1;
                            }
                            if (self.pending_dedents > 0) {
                                self.pending_dedents -= 1;
                                return .{ .tag = .dedent, .loc = .{ .start = start, .end = self.index } };
                            }
                        }

                        // Same indent level, return next token.
                        return self.next();
                    },
                }
            }
        }
    }
};

// Tests
test "simple tokens" {
    var tok = Tokenizer.init("fn main = 42");
    const t1 = tok.next();
    try std.testing.expectEqual(Token.Tag.keyword_fn, t1.tag);

    const t2 = tok.next();
    try std.testing.expectEqual(Token.Tag.identifier, t2.tag);

    const t3 = tok.next();
    try std.testing.expectEqual(Token.Tag.equal, t3.tag);

    const t4 = tok.next();
    try std.testing.expectEqual(Token.Tag.number, t4.tag);
}

test "string literal" {
    var tok = Tokenizer.init("\"hello world\"");
    const t = tok.next();
    try std.testing.expectEqual(Token.Tag.string, t.tag);
}

test "comment skipping" {
    var tok = Tokenizer.init("# this is a comment\n42");
    const t1 = tok.next();
    try std.testing.expectEqual(Token.Tag.comment, t1.tag);
    const t2 = tok.next();
    try std.testing.expectEqual(Token.Tag.number, t2.tag);
}

test "indentation" {
    var tok = Tokenizer.init("fn main =\n   42");
    const t1 = tok.next();
    try std.testing.expectEqual(Token.Tag.keyword_fn, t1.tag);

    // Skip to newline
    while (tok.next().tag != .newline) {}

    // Next should be indent
    const t2 = tok.next();
    try std.testing.expectEqual(Token.Tag.indent, t2.tag);
}
