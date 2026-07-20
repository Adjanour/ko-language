const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Literal = ast.Literal;
pub const TypeExpr = ast.TypeExpr;
pub const Pattern = ast.Pattern;
pub const RecordPatternField = ast.RecordPatternField;
pub const NamedArg = ast.NamedArg;
pub const FnCallExpr = ast.FnCallExpr;
pub const IfExpr = ast.IfExpr;
pub const LetExprExpr = ast.LetExprExpr;
pub const MatchArm = ast.MatchArm;
pub const BinaryOp = ast.BinaryOp;
pub const UnaryOp = ast.UnaryOp;
pub const Expr = ast.Expr;
pub const Constructor = ast.Constructor;
pub const RecordField = ast.RecordField;
pub const TypeDef = ast.TypeDef;
pub const FnParam = ast.FnParam;
pub const FnDef = ast.FnDef;
pub const LetBinding = ast.LetBinding;
pub const Import = ast.Import;
pub const Package = ast.Package;
pub const ModuleDef = ast.ModuleDef;
pub const Definition = ast.Definition;
pub const Program = ast.Program;
pub const Loc = ast.Loc;

pub const Parser = struct {
    pub const Error = error{ UnexpectedToken, OutOfMemory, InvalidCharacter, Overflow, InvalidBase };

    pub const ErrorContext = struct {
        message: []const u8,
        loc: Loc,
    };
    const top_level_stops = &.{
        .keyword_fn,
        .keyword_type,
        .keyword_let,
        .keyword_module,
        .keyword_import,
        .keyword_pub,
        .keyword_comptime,
    };

    const fn_body_stops = &.{
        .keyword_fn,
        .keyword_type,
        .keyword_module,
        .keyword_import,
        .keyword_pub,
        .keyword_comptime,
    };

    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []lexer.Token,
    pos: usize,
    allow_let_in_body: bool = false,
    pending_doc_comments: std.ArrayList([]const u8) = .empty,
    last_error: ?ErrorContext = null,

    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) Error!Parser {
        var tok = lexer.Tokenizer.init(source);
        var list: std.ArrayList(lexer.Token) = .empty;
        errdefer list.deinit(allocator);
        while (true) {
            const t = tok.next();
            try list.append(allocator, t);
            if (t.tag == .eof) break;
        }
        return .{ .allocator = allocator, .source = source, .tokens = try list.toOwnedSlice(allocator), .pos = 0 };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
    }

    fn current(self: *Parser) lexer.Token {
        return self.tokens[self.pos];
    }

    fn peek(self: *Parser, n: usize) lexer.Token {
        const idx = self.pos + n;
        if (idx >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[idx];
    }

    fn advance(self: *Parser) lexer.Token {
        const t = self.current();
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn match(self: *Parser, tag: lexer.Token.Tag) bool {
        if (self.current().tag != tag) return false;
        _ = self.advance();
        return true;
    }

    fn isInlineComment(self: *Parser) bool {
        if (self.pos == 0) return false;
        var i = self.pos - 1;
        while (i > 0 and self.tokens[i].tag == .newline) i -= 1;
        const prev = self.tokens[i];
        if (prev.tag == .newline or prev.tag == .indent or prev.tag == .dedent) return false;
        const between = self.source[prev.loc.end..self.current().loc.start];
        return std.mem.indexOfScalar(u8, between, '\n') == null;
    }

    fn expect(self: *Parser, tag: lexer.Token.Tag) !lexer.Token {
        if (self.current().tag != tag) {
            const found = self.current();
            const expected_name = tag.humanName();
            const found_name = found.tag.humanName();
            const loc = self.tokenLoc(found);
            if (found.tag == .identifier or found.tag == .constructor) {
                const text = self.slice(found);
                self.last_error = .{
                    .message = std.fmt.allocPrint(self.allocator, "expected {s}, got '{s}' ({s})", .{ expected_name, text, found_name }) catch "unexpected token",
                    .loc = loc,
                };
            } else {
                self.last_error = .{
                    .message = std.fmt.allocPrint(self.allocator, "expected {s}, got {s}", .{ expected_name, found_name }) catch "unexpected token",
                    .loc = loc,
                };
            }
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        const loc = self.tokenLoc(self.current());
        self.last_error = .{
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch "unexpected token",
            .loc = loc,
        };
        return error.UnexpectedToken;
    }

    fn slice(self: *Parser, token: lexer.Token) []const u8 {
        return self.source[token.loc.start..token.loc.end];
    }

    fn allocSlice(self: *Parser, comptime T: type, items: []const T) ![]const T {
        const out = try self.allocator.alloc(T, items.len);
        @memcpy(out, items);
        return out;
    }

    fn allocExprPtrSlice(self: *Parser, items: []const *Expr) ![]const *Expr {
        const out = try self.allocator.alloc(*Expr, items.len);
        @memcpy(out, items);
        return out;
    }

    fn lineCol(self: *Parser, tok: lexer.Token) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;
        var i: usize = 0;
        while (i < tok.loc.start and i < self.source.len) : (i += 1) {
            if (self.source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    fn tokenLoc(self: *Parser, tok: lexer.Token) Loc {
        const start = self.lineCol(tok);
        var end_line = start.line;
        var end_col = start.col;
        var i: usize = tok.loc.start;
        while (i < tok.loc.end and i < self.source.len) : (i += 1) {
            if (self.source[i] == '\n') {
                end_line += 1;
                end_col = 1;
            } else {
                end_col += 1;
            }
        }
        return .{ .line = start.line, .col = start.col, .end_line = end_line, .end_col = end_col };
    }

    fn newExpr(self: *Parser, expr: Expr, loc: Loc) !*Expr {
        const ptr = try self.allocator.create(Expr);
        ptr.* = expr;
        ptr.setLoc(loc);
        return ptr;
    }

    fn newPattern(self: *Parser, pattern: Pattern) !*Pattern {
        const ptr = try self.allocator.create(Pattern);
        ptr.* = pattern;
        return ptr;
    }

    fn is_expr_start(tag: lexer.Token.Tag) bool {
        return switch (tag) {
            .number, .string, .char, .identifier, .constructor, .keyword_true, .keyword_false,
            .lparen, .keyword_if, .keyword_match, .backslash, .keyword_not, .keyword_ref => true,
            else => false,
        };
    }

    fn is_stop(tag: lexer.Token.Tag, stop_tags: []const lexer.Token.Tag) bool {
        for (stop_tags) |s| if (tag == s) return true;
        return false;
    }

    fn skip_newlines(self: *Parser) void {
        while (self.current().tag == .newline) {
            _ = self.advance();
        }
    }

    fn skip_layout(self: *Parser) void {
        while (self.current().tag == .newline or self.current().tag == .indent or self.current().tag == .dedent or self.current().tag == .comment) {
            if (self.current().tag == .comment) {
                const loc = self.current().loc;
                const text = std.mem.trim(u8, self.source[loc.start..loc.end], " \t");
                if (text.len > 0) {
                    self.pending_doc_comments.append(self.allocator, text) catch {};
                }
            }
            _ = self.advance();
        }
    }

    // =========================================================================
    // Top-level
    // =========================================================================

    pub fn parse_program(self: *Parser) Error!Program {
        var imports: std.ArrayList(Import) = .empty;
        var defs: std.ArrayList(Definition) = .empty;
        var trailing: std.ArrayList(*Expr) = .empty;
        var package: ?[]const []const u8 = null;

        self.skip_layout();
        if (self.current().tag == .keyword_package) {
            const pkg = try self.parse_package();
            package = pkg.name;
            try defs.append(self.allocator, .{ .package = pkg });
            self.skip_layout();
        }

        while (self.current().tag != .eof) {
            self.skip_layout();
            if (self.current().tag == .eof) break;

            if (self.current().tag == .keyword_import) {
                try imports.append(self.allocator, try self.parse_import());
                continue;
            }

            if (self.current().tag == .keyword_pub) {
                _ = self.advance();
                if (self.current().tag == .keyword_fn) {
                    var fn_def = try self.parse_fn_def();
                    fn_def.is_pub = true;
                    fn_def.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .fn_def = fn_def });
                    continue;
                }
                if (self.current().tag == .keyword_type) {
                    var type_def = try self.parse_type_def();
                    type_def.is_pub = true;
                    type_def.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .type_def = type_def });
                    continue;
                }
                if (self.current().tag == .keyword_let) {
                    var let_def = try self.parse_let_binding();
                    let_def.is_pub = true;
                    let_def.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .let_binding = let_def });
                    continue;
                }
                if (self.current().tag == .keyword_module) {
                    var module_def = try self.parse_module_def();
                    module_def.is_pub = true;
                    try defs.append(self.allocator, .{ .module_def = module_def });
                    continue;
                }
                if (self.current().tag == .identifier and self.peek(1).tag == .equal) {
                    const name = self.slice(self.advance());
                    _ = try self.expect(.equal);
                    const value = try self.parse_expr();
                    const doc = self.collectDocComments();
                    try defs.append(self.allocator, .{ .let_binding = .{ .name = name, .type_ann = null, .value = value, .is_pub = true, .doc_comments = doc } });
                    continue;
                }
                return self.fail("expected 'fn', 'type', 'let', or definition after 'pub'", .{});
            }

            switch (self.current().tag) {
                .keyword_import => try imports.append(self.allocator, try self.parse_import()),
                .keyword_fn => {
                    var f = try self.parse_fn_def();
                    f.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .fn_def = f });
                },
                .keyword_type => {
                    var t = try self.parse_type_def();
                    t.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .type_def = t });
                },
                .keyword_let => {
                    var l = try self.parse_let_binding();
                    l.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .let_binding = l });
                },
                .keyword_module => {
                    var m = try self.parse_module_def();
                    m.doc_comments = self.collectDocComments();
                    try defs.append(self.allocator, .{ .module_def = m });
                },
                .keyword_comptime => {
                    _ = self.advance();
                    if (self.current().tag == .keyword_fn) {
                        var fn_def = try self.parse_fn_def();
                        fn_def.is_comptime = true;
                        fn_def.doc_comments = self.collectDocComments();
                        try defs.append(self.allocator, .{ .fn_def = fn_def });
                        continue;
                    }
                    return self.fail("expected 'fn' after 'comptime'", .{});
                },
                .identifier, .number, .string, .char, .keyword_true, .keyword_false,
                .lparen, .keyword_if, .keyword_match, .backslash, .keyword_ref, .minus, .keyword_not => {
                    try trailing.append(self.allocator, try self.parse_expr());
                },
                else => return self.fail("unexpected token at top level", .{}),
            }
            self.skip_layout();
        }

        if (trailing.items.len > 0 and !hasMain(defs.items)) {
            const body = if (trailing.items.len == 1)
                trailing.items[0]
            else
                try self.newExpr(.{ .block = .{ .items = try self.allocExprPtrSlice(trailing.items) } }, self.tokenLoc(self.current()));
            try defs.append(self.allocator, .{ .fn_def = .{
                .name = "main",
                .params = &.{},
                .return_type = null,
                .body = body,
                .is_pub = false,
                .is_comptime = false,
            } });
        }

        return .{
            .imports = try imports.toOwnedSlice(self.allocator),
            .definitions = try defs.toOwnedSlice(self.allocator),
            .package = package,
        };
    }

    fn hasMain(defs: []const Definition) bool {
        for (defs) |d| switch (d) {
            .fn_def => |f| if (std.mem.eql(u8, f.name, "main")) return true,
            else => {},
        };
        return false;
    }

    // =========================================================================
    // Import / Package / Module
    // =========================================================================

    fn parse_import(self: *Parser) Error!Import {
        _ = try self.expect(.keyword_import);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);

        if (self.current().tag == .string) {
            try parts.append(self.allocator, self.slice(self.advance()));
        } else {
            const name_token = self.current();
            if (name_token.tag != .identifier and name_token.tag != .constructor) return self.fail("expected module name after 'import'", .{});
            try parts.append(self.allocator, self.slice(self.advance()));
            while (self.match(.dot)) {
                if (self.current().tag == .lbrace or self.current().tag == .keyword_as) break;
                const part_token = self.current();
                if (part_token.tag != .identifier and part_token.tag != .constructor) return self.fail("expected module path component", .{});
                try parts.append(self.allocator, self.slice(self.advance()));
            }
        }

        var selective: ?[]const []const u8 = null;
        if (self.current().tag == .lbrace) {
            _ = self.advance();
            var sels: std.ArrayList([]const u8) = .empty;
            defer sels.deinit(self.allocator);
            while (self.current().tag != .rbrace) {
                const sel_token = self.current();
                if (sel_token.tag != .identifier and sel_token.tag != .constructor) return self.fail("expected name in selective import", .{});
                try sels.append(self.allocator, self.slice(self.advance()));
                if (self.current().tag != .rbrace) _ = try self.expect(.comma);
            }
            _ = try self.expect(.rbrace);
            selective = try self.allocSlice([]const u8, sels.items);
        }

        var alias: ?[]const u8 = null;
        if (self.match(.keyword_as)) alias = self.slice(try self.expect(.identifier));

        return .{
            .path = try self.allocSlice([]const u8, parts.items),
            .selective = selective,
            .alias = alias,
        };
    }

    fn parse_package(self: *Parser) Error!Package {
        _ = try self.expect(.keyword_package);
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        try parts.append(self.allocator, self.slice(try self.expect(.identifier)));
        while (self.match(.dot)) try parts.append(self.allocator, self.slice(try self.expect(.identifier)));
        return .{ .name = try self.allocSlice([]const u8, parts.items) };
    }

    fn parse_module_def(self: *Parser) Error!ModuleDef {
        _ = try self.expect(.keyword_module);
        const name_token = self.current();
        if (name_token.tag != .identifier and name_token.tag != .constructor) return self.fail("expected module name", .{});
        const name = self.slice(self.advance());
        const defs = try self.parse_block_defs();
        // Consume the dedent that ends the module block
        if (self.current().tag == .dedent) _ = self.advance();
        return .{ .name = name, .definitions = defs, .is_pub = false };
    }

    fn parse_block_defs(self: *Parser) Error![]const Definition {
        self.skip_newlines();
        if (self.match(.indent)) self.skip_newlines();
        var defs: std.ArrayList(Definition) = .empty;
        defer defs.deinit(self.allocator);
        while (self.current().tag != .eof and self.current().tag != .dedent) {
            try defs.append(self.allocator, try self.parse_definition_in_scope());
            self.skip_newlines();
        }
        // Don't consume the dedent — let the caller handle it
        return try defs.toOwnedSlice(self.allocator);
    }

    fn collectDocComments(self: *Parser) ?[]const []const u8 {
        if (self.pending_doc_comments.items.len == 0) return null;
        const result = self.pending_doc_comments.toOwnedSlice(self.allocator) catch return null;
        self.pending_doc_comments = .empty;
        return result;
    }

    fn parse_definition_in_scope(self: *Parser) Error!Definition {
        var is_pub = false;
        if (self.match(.keyword_pub)) is_pub = true;
        return switch (self.current().tag) {
            .keyword_fn => blk: {
                var f = try self.parse_fn_def();
                f.is_pub = is_pub;
                f.doc_comments = self.collectDocComments();
                break :blk .{ .fn_def = f };
            },
            .keyword_type => blk: {
                var t = try self.parse_type_def();
                t.is_pub = is_pub;
                t.doc_comments = self.collectDocComments();
                break :blk .{ .type_def = t };
            },
            .keyword_let => blk: {
                var l = try self.parse_let_binding();
                l.is_pub = is_pub;
                l.doc_comments = self.collectDocComments();
                break :blk .{ .let_binding = l };
            },
            .keyword_module => blk: {
                var m = try self.parse_module_def();
                m.is_pub = is_pub;
                m.doc_comments = self.collectDocComments();
                break :blk .{ .module_def = m };
            },
            else => error.UnexpectedToken,
        };
    }

    // =========================================================================
    // Definitions
    // =========================================================================

    fn parse_type_def(self: *Parser) Error!TypeDef {
        _ = try self.expect(.keyword_type);
        const name_token = self.current();
        if (name_token.tag != .identifier and name_token.tag != .constructor) return self.fail("expected type name", .{});
        const name = self.slice(self.advance());
        var type_params: std.ArrayList([]const u8) = .empty;
        defer type_params.deinit(self.allocator);
        while (self.current().tag == .identifier) {
            try type_params.append(self.allocator, self.slice(self.advance()));
        }
        _ = try self.expect(.equal);
        self.skip_newlines();
        if (self.current().tag == .indent) {
            _ = self.advance();
            self.skip_newlines();
        }
        if (self.current().tag == .lbrace) {
            var fields: std.ArrayList(RecordField) = .empty;
            defer fields.deinit(self.allocator);
            _ = self.advance();
            self.skip_layout();
            while (self.current().tag != .rbrace and self.current().tag != .eof) {
                self.skip_layout();
                const field_name = self.slice(try self.expect(.identifier));
                _ = try self.expect(.colon);
                const field_type = try self.parse_type_expr();
                try fields.append(self.allocator, .{ .name = field_name, .type_expr = field_type });
                self.skip_layout();
                if (self.match(.comma)) {
                    self.skip_layout();
                    continue;
                }
                break;
            }
            _ = try self.expect(.rbrace);
            return .{
                .name = name,
                .type_params = try self.allocSlice([]const u8, type_params.items),
                .body = .{ .record = try self.allocSlice(RecordField, fields.items) },
                .is_pub = false,
            };
        }

        var ctors: std.ArrayList(Constructor) = .empty;
        defer ctors.deinit(self.allocator);
        self.skip_newlines();
        while (true) {
            try ctors.append(self.allocator, try self.parse_constructor());
            self.skip_newlines();
            if (self.match(.pipe)) {
                self.skip_newlines();
                continue;
            }
            break;
        }
        return .{
            .name = name,
            .type_params = try self.allocSlice([]const u8, type_params.items),
            .body = .{ .sum = try ctors.toOwnedSlice(self.allocator) },
            .is_pub = false,
        };
    }

    fn parse_constructor(self: *Parser) Error!Constructor {
        const name_token = self.current();
        if (name_token.tag != .identifier and name_token.tag != .constructor) return self.fail("expected constructor name", .{});
        const name = self.slice(self.advance());
        var params: std.ArrayList(TypeExpr) = .empty;
        defer params.deinit(self.allocator);
        while (self.current().tag == .identifier or self.current().tag == .constructor or
            self.current().tag == .lparen or self.current().tag == .lbrace)
        {
            try params.append(self.allocator, try self.parse_type_primary());
        }
        return .{ .name = name, .params = try self.allocSlice(TypeExpr, params.items) };
    }

    fn parse_fn_def(self: *Parser) Error!FnDef {
        _ = try self.expect(.keyword_fn);
        const name = self.slice(try self.expect(.identifier));
        var params: std.ArrayList(FnParam) = .empty;
        defer params.deinit(self.allocator);

        while (true) {
            if (self.current().tag == .tilde) {
                break;
            }
            if (self.current().tag == .keyword_ref or self.current().tag == .minus or
                self.current().tag == .keyword_not or self.current().tag == .underscore or
                self.current().tag == .number or self.current().tag == .string or
                self.current().tag == .char or self.current().tag == .keyword_true or
                self.current().tag == .keyword_false or self.current().tag == .lparen or
                (self.current().tag == .identifier) or (self.current().tag == .constructor))
            {
                const pat = try self.parse_pattern();
                var type_ann: ?TypeExpr = null;
                if (self.match(.colon)) {
                    type_ann = try self.parse_type_expr();
                }
                try params.append(self.allocator, .{ .pattern = pat, .type_ann = type_ann });
                continue;
            }
            break;
        }

        var return_type: ?TypeExpr = null;
        if (self.match(.colon)) {
            return_type = try self.parse_type_expr();
        }

        _ = try self.expect(.equal);
        const body = try self.parse_block(top_level_stops, true);
        return .{
            .name = name,
            .params = try self.allocSlice(FnParam, params.items),
            .return_type = return_type,
            .body = body,
            .is_pub = false,
            .is_comptime = false,
        };
    }

    fn parse_let_binding(self: *Parser) Error!LetBinding {
        _ = try self.expect(.keyword_let);
        const name = self.slice(try self.expect(.identifier));
        var type_ann: ?TypeExpr = null;
        if (self.match(.colon)) {
            type_ann = try self.parse_type_expr();
        }
        _ = try self.expect(.equal);
        const value = try self.parse_expr();
        return .{ .name = name, .type_ann = type_ann, .value = value, .is_pub = false };
    }

    // =========================================================================
    // Blocks
    // =========================================================================

    fn parse_block(self: *Parser, stop_tags: []const lexer.Token.Tag, consume_dedent: bool) Error!*Expr {
        self.skip_newlines();
        const is_indented = self.match(.indent);
        if (is_indented) self.skip_newlines();

        var exprs: std.ArrayList(*Expr) = .empty;
        defer exprs.deinit(self.allocator);

        while (self.current().tag != .eof) {
            if (self.current().tag == .comment and !is_indented and !self.isInlineComment()) break;
            if (self.current().tag == .dedent) {
                if (!is_indented) break;
                if (consume_dedent) _ = self.advance();
                break;
            }
            if (self.current().tag == .keyword_let) {
                if (is_indented or self.allow_let_in_body) {
                    const le = try self.parse_let_expr_in_block(stop_tags);
                    try exprs.append(self.allocator, le);
                    self.skip_newlines();
                    continue;
                }
            }
            if (Parser.is_stop(self.current().tag, stop_tags) and is_indented) break;
            if (!is_indented and Parser.is_stop(self.current().tag, stop_tags)) break;
            if (self.current().tag == .newline or (self.current().tag == .comment and (is_indented or self.isInlineComment()))) {
                _ = self.advance();
                continue;
            }
            try exprs.append(self.allocator, try self.parse_expr());
            self.skip_newlines();
        }

        if (exprs.items.len == 0) return self.newExpr(.{ .block = .{ .items = &.{} } }, self.tokenLoc(self.current()));
        if (exprs.items.len == 1) return exprs.items[0];
        return self.newExpr(.{ .block = .{ .items = try self.allocExprPtrSlice(exprs.items) } }, self.tokenLoc(self.current()));
    }

    fn parse_let_expr_in_block(self: *Parser, stop_tags: []const lexer.Token.Tag) Error!*Expr {
        _ = try self.expect(.keyword_let);
        var name: []const u8 = "";
        var type_ann: ?TypeExpr = null;
        var pattern: ?Pattern = null;

        if (self.current().tag == .lparen) {
            // Tuple destructuring: let (x, y) = ...
            _ = self.advance();
            var items: std.ArrayList(Pattern) = .empty;
            defer items.deinit(self.allocator);
            try items.append(self.allocator, try self.parse_pattern());
            while (self.match(.comma)) {
                try items.append(self.allocator, try self.parse_pattern());
            }
            _ = try self.expect(.rparen);
            pattern = .{ .tuple = try self.allocSlice(Pattern, items.items) };
        } else {
            name = self.slice(try self.expect(.identifier));
            if (self.match(.colon)) {
                type_ann = try self.parse_type_expr();
            }
        }

        _ = try self.expect(.equal);
        const value = try self.parse_expr();

        self.skip_newlines();
        while (self.current().tag == .comment) {
            _ = self.advance();
        }
        if (self.current().tag == .dedent) _ = self.advance();
        self.skip_newlines();
        while (self.current().tag == .comment) {
            _ = self.advance();
        }
        var body: *Expr = undefined;
        if (self.current().tag == .keyword_let) {
            body = try self.parse_let_expr_in_block(stop_tags);
        } else if (self.current().tag == .dedent or self.current().tag == .eof or Parser.is_stop(self.current().tag, stop_tags)) {
            body = try self.newExpr(.{ .block = .{ .items = &.{} } }, self.tokenLoc(self.current()));
        } else {
            const prev = self.allow_let_in_body;
            self.allow_let_in_body = true;
            body = try self.parse_block(fn_body_stops, true);
            self.allow_let_in_body = prev;
        }
        return self.newExpr(.{ .let_expr = .{ .name = name, .type_ann = type_ann, .value = value, .body = body, .pattern = pattern } }, self.tokenLoc(self.current()));
    }

    // =========================================================================
    // Type expressions
    // =========================================================================

    fn parse_type_expr(self: *Parser) Error!TypeExpr {
        const from = try self.parse_type_atom();
        if (self.match(.arrow)) {
            const to = try self.parse_type_expr();
            return .{ .arrow = .{ .from = try self.newTypeExpr(from), .to = try self.newTypeExpr(to) } };
        }
        return from;
    }

    fn parse_type_atom(self: *Parser) Error!TypeExpr {
        var func = try self.parse_type_primary();
        while (self.is_type_primary_start()) {
            const arg = try self.parse_type_primary();
            func = .{ .application = .{ .func = try self.newTypeExpr(func), .arg = try self.newTypeExpr(arg) } };
        }
        return func;
    }

    fn is_type_primary_start(self: *Parser) bool {
        return switch (self.current().tag) {
            .identifier, .constructor, .lparen, .lbrace => true,
            else => false,
        };
    }

    fn parse_type_primary(self: *Parser) Error!TypeExpr {
        const t = self.current();
        switch (t.tag) {
            .identifier => {
                _ = self.advance();
                return .{ .ident = self.slice(t) };
            },
            .constructor => {
                _ = self.advance();
                return .{ .constructor = self.slice(t) };
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parse_type_expr();
                _ = try self.expect(.rparen);
                return .{ .group = try self.newTypeExpr(inner) };
            },
            .lbrace => {
                var fields: std.ArrayList(RecordField) = .empty;
                defer fields.deinit(self.allocator);
                _ = self.advance();
                self.skip_layout();
                while (self.current().tag != .rbrace and self.current().tag != .eof) {
                    self.skip_layout();
                    const field_name = self.slice(try self.expect(.identifier));
                    _ = try self.expect(.colon);
                    const field_type = try self.parse_type_expr();
                    try fields.append(self.allocator, .{ .name = field_name, .type_expr = field_type });
                    self.skip_layout();
                    if (self.match(.comma)) {
                        self.skip_layout();
                        continue;
                    }
                    break;
                }
                _ = try self.expect(.rbrace);
                return .{ .record = try self.allocSlice(RecordField, fields.items) };
            },
            else => return self.fail("expected type expression", .{}),
        }
    }

    fn newTypeExpr(self: *Parser, te: TypeExpr) !*TypeExpr {
        const ptr = try self.allocator.create(TypeExpr);
        ptr.* = te;
        return ptr;
    }

    // =========================================================================
    // Expressions
    // =========================================================================

    fn parse_expr(self: *Parser) Error!*Expr {
        return self.parse_assign();
    }

    fn parse_assign(self: *Parser) Error!*Expr {
        const left = try self.parse_pipe();
        if (self.match(.colon_equal)) {
            const value = try self.parse_expr();
            return self.newExpr(.{ .assign_expr = .{ .target = left, .value = value } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_pipe(self: *Parser) Error!*Expr {
        var left = try self.parse_cons();
        while (self.match(.pipe_gt)) {
            const right = try self.parse_cons();
            switch (right.*) {
                .fn_call => |call| {
                    var args: std.ArrayList(*Expr) = .empty;
                    defer args.deinit(self.allocator);
                    try args.append(self.allocator, left);
                    for (call.args) |arg| try args.append(self.allocator, arg);
                    right.* = .{ .fn_call = .{
                        .func = call.func,
                        .args = try self.allocExprPtrSlice(args.items),
                        .named_args = call.named_args,
                    } };
                    left = right;
                },
                else => {
                    const call = try self.newExpr(.{ .fn_call = .{ .func = right, .args = try self.allocExprPtrSlice(&.{ left }), .named_args = &.{} } }, self.tokenLoc(self.current()));
                    left = call;
                },
            }
        }
        return left;
    }

    fn parse_cons(self: *Parser) Error!*Expr {
        var left = try self.parse_or();
        if (self.match(.double_colon)) {
            const right = try self.parse_cons();
            left = try self.newExpr(.{ .binary_op = .{ .op = .cons, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_or(self: *Parser) Error!*Expr {
        var left = try self.parse_and();
        while (self.current().tag == .or_or or self.current().tag == .keyword_or) {
            _ = self.advance();
            const right = try self.parse_and();
            left = try self.newExpr(.{ .binary_op = .{ .op = .or_op, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_and(self: *Parser) Error!*Expr {
        var left = try self.parse_equality();
        while (self.current().tag == .and_and or self.current().tag == .keyword_and) {
            _ = self.advance();
            const right = try self.parse_equality();
            left = try self.newExpr(.{ .binary_op = .{ .op = .and_op, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_equality(self: *Parser) Error!*Expr {
        var left = try self.parse_compare();
        while (self.current().tag == .equal_equal or self.current().tag == .not_equal) {
            const op = if (self.current().tag == .equal_equal) BinaryOp.eq else BinaryOp.neq;
            _ = self.advance();
            const right = try self.parse_compare();
            left = try self.newExpr(.{ .binary_op = .{ .op = op, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_compare(self: *Parser) Error!*Expr {
        var left = try self.parse_term();
        while (true) {
            const op: ?BinaryOp = switch (self.current().tag) {
                .less_than => .lt,
                .less_equal => .lte,
                .greater_than => .gt,
                .greater_equal => .gte,
                else => null,
            };
            if (op == null) break;
            _ = self.advance();
            const right = try self.parse_term();
            left = try self.newExpr(.{ .binary_op = .{ .op = op.?, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_term(self: *Parser) Error!*Expr {
        var left = try self.parse_factor();
        while (self.current().tag == .plus or self.current().tag == .minus) {
            const op = if (self.current().tag == .plus) BinaryOp.add else BinaryOp.sub;
            _ = self.advance();
            const right = try self.parse_factor_no_prefix();
            left = try self.newExpr(.{ .binary_op = .{ .op = op, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_factor(self: *Parser) Error!*Expr {
        var left = try self.parse_unary();
        while (self.current().tag == .star or self.current().tag == .slash or self.current().tag == .percent) {
            const op = switch (self.current().tag) {
                .star => BinaryOp.mul,
                .slash => BinaryOp.div,
                else => BinaryOp.mod,
            };
            _ = self.advance();
            const right = try self.parse_unary_no_prefix();
            left = try self.newExpr(.{ .binary_op = .{ .op = op, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    fn parse_unary(self: *Parser) Error!*Expr {
        if (self.match(.minus)) return self.newExpr(.{ .unary_op = .{ .op = .neg, .expr = try self.parse_unary() } }, self.tokenLoc(self.current()));
        return self.parse_unary_no_prefix();
    }

    fn parse_unary_no_prefix(self: *Parser) Error!*Expr {
        if (self.match(.keyword_not)) return self.newExpr(.{ .unary_op = .{ .op = .not, .expr = try self.parse_unary() } }, self.tokenLoc(self.current()));
        if (self.match(.not)) return self.newExpr(.{ .unary_op = .{ .op = .deref, .expr = try self.parse_unary() } }, self.tokenLoc(self.current()));
        if (self.match(.keyword_ref)) return self.newExpr(.{ .ref_expr = try self.parse_unary() }, self.tokenLoc(self.current()));
        return self.parse_postfix();
    }

    fn parse_factor_no_prefix(self: *Parser) Error!*Expr {
        var left = try self.parse_unary_no_prefix();
        while (self.current().tag == .star or self.current().tag == .slash or self.current().tag == .percent) {
            const op = switch (self.current().tag) {
                .star => BinaryOp.mul,
                .slash => BinaryOp.div,
                else => BinaryOp.mod,
            };
            _ = self.advance();
            const right = try self.parse_unary_no_prefix();
            left = try self.newExpr(.{ .binary_op = .{ .op = op, .left = left, .right = right } }, self.tokenLoc(self.current()));
        }
        return left;
    }

    /// Parse field access chains and record literals, but NOT function application.
    /// Used for parsing function arguments so that `println pt.x` → `println(pt.x)`.
    fn parse_postfix_no_apply(self: *Parser) Error!*Expr {
        var expr = try self.parse_primary();
        while (true) {
            if (self.match(.dot)) {
                const tag = self.current().tag;
                if (tag != .identifier and tag != .constructor) return self.fail("expected field name after '.'", .{});
                const field_tok = self.current();
                const field = self.slice(field_tok);
                _ = self.advance();
                expr = try self.newExpr(.{ .field_access = .{ .object = expr, .field = field } }, self.tokenLoc(field_tok));
                continue;
            }

            // Handle record literal after field access (e.g., Geo.Point { x = 1 })
            if (self.current().tag == .lbrace and expr.* == .field_access) {
                const fa = expr.field_access;
                if (fa.object.* == .constructor) {
                    const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ fa.object.constructor.name, fa.field });
                    expr = try self.parse_record_literal(combined);
                    continue;
                }
            }

            // Postfix ? operator (try/unwrap Result)
            if (self.match(.question)) {
                expr = try self.newExpr(.{ .unary_op = .{ .op = .try_op, .expr = expr } }, self.tokenLoc(self.current()));
                continue;
            }

            break;
        }
        return expr;
    }

    fn parse_postfix(self: *Parser) Error!*Expr {
        var expr = try self.parse_primary();
        while (true) {
            if (self.match(.dot)) {
                const tag = self.current().tag;
                if (tag != .identifier and tag != .constructor) return self.fail("expected field name after '.'", .{});
                const field_tok = self.current();
                const field = self.slice(field_tok);
                _ = self.advance();
                expr = try self.newExpr(.{ .field_access = .{ .object = expr, .field = field } }, self.tokenLoc(field_tok));
                continue;
            }

            // Handle record literal after field access (e.g., Geo.Point { x = 1 })
            if (self.current().tag == .lbrace and expr.* == .field_access) {
                const fa = expr.field_access;
                if (fa.object.* == .constructor) {
                    // Geo.Point { ... } → record literal with name "Geo.Point"
                    const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ fa.object.constructor.name, fa.field });
                    expr = try self.parse_record_literal(combined);
                    continue;
                }
            }

            // Postfix ? operator (try/unwrap Result) — binds tighter than application
            if (self.current().tag == .question) {
                _ = self.advance();
                expr = try self.newExpr(.{ .unary_op = .{ .op = .try_op, .expr = expr } }, self.tokenLoc(self.current()));
                continue;
            }

            if (!is_expr_start(self.current().tag) and self.current().tag != .tilde) break;

            var args: std.ArrayList(*Expr) = .empty;
            defer args.deinit(self.allocator);
            var named: std.ArrayList(NamedArg) = .empty;
            defer named.deinit(self.allocator);

            while (true) {
                if (self.current().tag == .tilde) {
                    _ = self.advance();
                    const name = self.slice(try self.expect(.identifier));
                    _ = try self.expect(.colon);
                    const value = try self.parse_expr();
                    try named.append(self.allocator, .{ .name = name, .value = value });
                    continue;
                }
                if (!is_expr_start(self.current().tag)) break;
                // Use parse_postfix_no_apply so field access binds tighter than application
                try args.append(self.allocator, try self.parse_postfix_no_apply());
            }

            if (args.items.len == 0 and named.items.len == 0) break;
            expr = try self.newExpr(.{ .fn_call = .{
                .func = expr,
                .args = try self.allocExprPtrSlice(args.items),
                .named_args = try self.allocSlice(NamedArg, named.items),
            } }, self.tokenLoc(self.current()));
        }
        return expr;
    }

    fn parse_primary(self: *Parser) Error!*Expr {
        const t = self.current();
        switch (t.tag) {
            .number => {
                _ = self.advance();
                const s = self.slice(t);
                if (std.mem.indexOfScalar(u8, s, '.') != null) {
                    return self.newExpr(.{ .float_literal = try std.fmt.parseFloat(f64, s) }, self.tokenLoc(t));
                }
                if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
                    return self.newExpr(.{ .int_literal = try std.fmt.parseInt(i64, s[2..], 16) }, self.tokenLoc(t));
                }
                if (std.mem.startsWith(u8, s, "0b") or std.mem.startsWith(u8, s, "0B")) {
                    return self.newExpr(.{ .int_literal = try std.fmt.parseInt(i64, s[2..], 2) }, self.tokenLoc(t));
                }
                if (std.mem.startsWith(u8, s, "0o") or std.mem.startsWith(u8, s, "0O")) {
                    return self.newExpr(.{ .int_literal = try std.fmt.parseInt(i64, s[2..], 8) }, self.tokenLoc(t));
                }
                return self.newExpr(.{ .int_literal = try std.fmt.parseInt(i64, s, 10) }, self.tokenLoc(t));
            },
            .string => return self.newExpr(.{ .string_literal = self.slice(self.advance()) }, self.tokenLoc(t)),
            .char => return self.newExpr(.{ .char_literal = self.slice(self.advance()) }, self.tokenLoc(t)),
            .keyword_true => { _ = self.advance(); return self.newExpr(.{ .bool_literal = true }, self.tokenLoc(t)); },
            .keyword_false => { _ = self.advance(); return self.newExpr(.{ .bool_literal = false }, self.tokenLoc(t)); },
            .identifier => {
                const name = self.slice(self.advance());
                if (name.len > 0 and std.ascii.isUpper(name[0])) {
                    if (self.current().tag == .lbrace) return self.parse_record_literal(name);
                    return self.newExpr(.{ .constructor = .{ .name = name } }, self.tokenLoc(t));
                }
                return self.newExpr(.{ .identifier = .{ .name = name } }, self.tokenLoc(t));
            },
            .constructor => {
                const name = self.slice(self.advance());
                if (self.current().tag == .lbrace) return self.parse_record_literal(name);
                return self.newExpr(.{ .constructor = .{ .name = name } }, self.tokenLoc(t));
            },
            .lparen => return self.parse_group_or_tuple(),
            .backslash => return self.parse_lambda(),
            .keyword_comptime => return self.parse_comptime(),
            .keyword_if => return self.parse_if(),
            .keyword_match => return self.parse_match(),
            else => return self.fail("expected expression", .{}),
        }
    }

    fn parse_comptime(self: *Parser) Error!*Expr {
        _ = try self.expect(.keyword_comptime);
        const expr = try self.parse_expr();
        return self.newExpr(.{ .comptime_expr = expr }, self.tokenLoc(self.current()));
    }

    fn parse_group_or_tuple(self: *Parser) Error!*Expr {
        _ = try self.expect(.lparen);
        if (self.current().tag == .rparen) {
            _ = self.advance();
            return self.newExpr(.{ .tuple = .{ .items = &.{} } }, self.tokenLoc(self.current()));
        }
        var items: std.ArrayList(*Expr) = .empty;
        defer items.deinit(self.allocator);
        try items.append(self.allocator, try self.parse_expr());
        while (self.match(.comma)) try items.append(self.allocator, try self.parse_expr());
        _ = try self.expect(.rparen);
        if (items.items.len == 1) return items.items[0];
        return self.newExpr(.{ .tuple = .{ .items = try self.allocExprPtrSlice(items.items) } }, self.tokenLoc(self.current()));
    }

    fn parse_lambda(self: *Parser) Error!*Expr {
        _ = try self.expect(.backslash);
        var params: std.ArrayList(Pattern) = .empty;
        defer params.deinit(self.allocator);
        while (is_pattern_start(self.current().tag)) {
            try params.append(self.allocator, try self.parse_pattern());
        }
        _ = try self.expect(.arrow);
        self.skip_newlines();
        const body = if (self.current().tag == .indent)
            try self.parse_block(&.{}, false)
        else
            try self.parse_expr();
        return self.newExpr(.{ .lambda = .{ .params = try self.allocSlice(Pattern, params.items), .body = body } }, self.tokenLoc(self.current()));
    }

    fn parse_if(self: *Parser) Error!*Expr {
        _ = try self.expect(.keyword_if);
        const cond = try self.parse_expr();
        self.skip_newlines();
        _ = self.match(.keyword_then);
        self.skip_newlines();
        const then_branch = if (self.current().tag == .indent)
            try self.parse_block(&.{.keyword_else}, true)
        else
            try self.parse_expr();
        self.skip_newlines();
        var else_branch: ?*Expr = null;
        if (self.match(.keyword_else)) {
            self.skip_newlines();
            else_branch = if (self.current().tag == .indent)
                try self.parse_block(&.{.dedent}, true)
            else
                try self.parse_expr();
        }
        return self.newExpr(.{ .if_expr = .{ .condition = cond, .then_branch = then_branch, .else_branch = else_branch } }, self.tokenLoc(self.current()));
    }

    fn parse_match(self: *Parser) Error!*Expr {
        _ = try self.expect(.keyword_match);
        const value = try self.parse_expr();
        self.skip_newlines();
        const has_indent = self.match(.indent);
        if (has_indent) self.skip_newlines();
        var arms: std.ArrayList(MatchArm) = .empty;
        defer arms.deinit(self.allocator);
        while (self.current().tag != .eof and self.current().tag != .dedent) {
            if (self.match(.pipe)) {
                self.skip_newlines();
            }
            if (!looks_like_pattern(self.current().tag)) break;
            const pat = try self.parse_pattern();
            _ = try self.expect(.fat_arrow);
            self.skip_newlines();
            const body = if (self.current().tag == .newline or self.current().tag == .indent)
                try self.parse_block(&.{.pipe, .dedent}, true)
            else
                try self.parse_expr();
            try arms.append(self.allocator, .{ .pattern = pat, .body = body });
            self.skip_newlines();
        }
        if (has_indent and self.current().tag == .dedent) _ = self.advance();
        return self.newExpr(.{ .match_expr = .{ .value = value, .arms = try self.allocSlice(MatchArm, arms.items) } }, self.tokenLoc(self.current()));
    }

    fn parse_record_literal(self: *Parser, name: []const u8) Error!*Expr {
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(NamedArg) = .empty;
        defer fields.deinit(self.allocator);
        self.skip_layout();
        while (self.current().tag != .rbrace and self.current().tag != .eof) {
            self.skip_layout();
            const field_name = self.slice(try self.expect(.identifier));
            _ = try self.expect(.equal);
            try fields.append(self.allocator, .{ .name = field_name, .value = try self.parse_expr() });
            self.skip_layout();
            if (self.match(.comma)) {
                self.skip_layout();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbrace);
        return self.newExpr(.{ .record_literal = .{ .name = name, .fields = try self.allocSlice(NamedArg, fields.items) } }, self.tokenLoc(self.current()));
    }

    // =========================================================================
    // Patterns
    // =========================================================================

    fn parse_pattern(self: *Parser) Error!Pattern {
        const t = self.current();
        switch (t.tag) {
            .underscore => { _ = self.advance(); return .wildcard; },
            .number => {
                const lit = try self.parse_primary();
                switch (lit.*) {
                    .int_literal => |v| return .{ .literal = .{ .int = v } },
                    .float_literal => |v| return .{ .literal = .{ .float = v } },
                else => return self.fail("unexpected token at top level", .{}),
                }
            },
            .string => {
                _ = self.advance();
                return .{ .literal = .{ .string = self.slice(t) } };
            },
            .char => {
                _ = self.advance();
                return .{ .literal = .{ .char = self.slice(t) } };
            },
            .keyword_true => { _ = self.advance(); return .{ .literal = .{ .bool = true } }; },
            .keyword_false => { _ = self.advance(); return .{ .literal = .{ .bool = false } }; },
            .identifier => {
                const name = self.slice(self.advance());
                if (name.len > 0 and std.ascii.isUpper(name[0])) {
                    if (self.current().tag == .lbrace) return self.parse_record_pattern(name);
                    var args: std.ArrayList(Pattern) = .empty;
                    defer args.deinit(self.allocator);
                    while (looks_like_pattern(self.current().tag)) {
                        if (self.current().tag == .arrow) break;
                        try args.append(self.allocator, try self.parse_pattern());
                    }
                    return .{ .constructor = .{ .name = name, .args = try self.allocSlice(Pattern, args.items) } };
                }
                return .{ .identifier = name };
            },
            .constructor => {
                const name = self.slice(self.advance());
                if (self.current().tag == .lbrace) return self.parse_record_pattern(name);
                var args: std.ArrayList(Pattern) = .empty;
                defer args.deinit(self.allocator);
                while (looks_like_pattern(self.current().tag)) {
                    if (self.current().tag == .arrow) break;
                    try args.append(self.allocator, try self.parse_pattern());
                }
                return .{ .constructor = .{ .name = name, .args = try self.allocSlice(Pattern, args.items) } };
            },
            .lparen => {
                _ = self.advance();
                var items: std.ArrayList(Pattern) = .empty;
                defer items.deinit(self.allocator);
                try items.append(self.allocator, try self.parse_pattern());
                while (self.match(.comma)) try items.append(self.allocator, try self.parse_pattern());
                _ = try self.expect(.rparen);
                if (items.items.len == 1) return items.items[0];
                return .{ .tuple = try self.allocSlice(Pattern, items.items) };
            },
            else => return self.fail("expected pattern", .{}),
        }
    }

    fn parse_record_pattern(self: *Parser, name: []const u8) Error!Pattern {
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(RecordPatternField) = .empty;
        defer fields.deinit(self.allocator);
        var rest = false;
        self.skip_layout();
        while (self.current().tag != .rbrace and self.current().tag != .eof) {
            self.skip_layout();
            if (self.current().tag == .dot and self.peek(1).tag == .dot) {
                _ = self.advance();
                _ = self.advance();
                rest = true;
                break;
            }
            const field_name = self.slice(try self.expect(.identifier));
            var value: ?*Pattern = null;
            if (self.match(.equal)) value = try self.newPattern(try self.parse_pattern());
            try fields.append(self.allocator, .{ .name = field_name, .pattern = value });
            self.skip_layout();
            if (self.match(.comma)) {
                self.skip_layout();
                continue;
            }
            break;
        }
        _ = try self.expect(.rbrace);
        return .{ .record = .{ .name = name, .fields = try self.allocSlice(RecordPatternField, fields.items), .rest = rest } };
    }

    fn skip_type_annotation(self: *Parser, stop_tags: []const lexer.Token.Tag) void {
        var depth: usize = 0;
        while (self.current().tag != .eof) {
            const tag = self.current().tag;
            if (depth == 0 and Parser.is_stop(tag, stop_tags)) break;
            switch (tag) {
                .lparen, .lbrace, .lbracket => depth += 1,
                .rparen, .rbrace, .rbracket => {
                    if (depth > 0) {
                        depth -= 1;
                    } else {
                        return;
                    }
                },
                else => {},
            }
            _ = self.advance();
        }
    }
};

fn looks_like_pattern(tag: lexer.Token.Tag) bool {
    return switch (tag) {
        .underscore, .number, .string, .char, .keyword_true, .keyword_false, .identifier, .constructor, .lparen => true,
        else => false,
    };
}

fn is_pattern_start(tag: lexer.Token.Tag) bool {
    return looks_like_pattern(tag);
}

test {
    _ = @import("lexer.zig");
}
