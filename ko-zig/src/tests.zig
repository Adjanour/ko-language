const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");

test "lexer: keywords" {
    var tok = lexer.Tokenizer.init("fn let if then else match type import package pub module true false and or not");
    try std.testing.expectEqual(lexer.Token.Tag.keyword_fn, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_let, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_if, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_then, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_else, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_match, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_type, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_import, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_package, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_pub, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_module, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_true, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_false, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_and, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_or, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_not, tok.next().tag);
}

test "lexer: operators" {
    var tok = lexer.Tokenizer.init("+ - * / % = == != < <= > -> => |> && || ! & | \\ ~");
    try std.testing.expectEqual(lexer.Token.Tag.plus, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.minus, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.star, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.slash, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.percent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.equal_equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.not_equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.less_than, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.less_equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.greater_than, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.arrow, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.fat_arrow, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.pipe_gt, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.and_and, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.or_or, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.not, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.ampersand, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.pipe, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.backslash, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.tilde, tok.next().tag);
}

test "lexer: standalone underscore" {
    var tok = lexer.Tokenizer.init("_");
    try std.testing.expectEqual(lexer.Token.Tag.underscore, tok.next().tag);
}

test "lexer: hyphenated identifier" {
    var tok = lexer.Tokenizer.init("map-maybe");
    try std.testing.expectEqual(lexer.Token.Tag.identifier, tok.next().tag);
}

test "lexer: delimiters" {
    var tok = lexer.Tokenizer.init("( ) { } [ ] , : ; . _");
    try std.testing.expectEqual(lexer.Token.Tag.lparen, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.rparen, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.lbrace, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.rbrace, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.lbracket, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.rbracket, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.comma, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.colon, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.semicolon, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.dot, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.underscore, tok.next().tag);
}

test "lexer: literals" {
    var tok = lexer.Tokenizer.init("42 3.14 0xFF 0b1010 0o755 1_000 \"hello\" 'c' '\\n' true false");
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.string, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.char, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.char, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_true, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_false, tok.next().tag);
}

test "lexer: comments skipped" {
    var tok = lexer.Tokenizer.init("# comment\n42");
    const t = tok.next();
    try std.testing.expectEqual(lexer.Token.Tag.number, t.tag);
}

test "lexer: comment line inside indent" {
    var tok = lexer.Tokenizer.init("fn main =\n  # comment\n  42");
    try std.testing.expectEqual(lexer.Token.Tag.keyword_fn, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.identifier, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.newline, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.indent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
}

test "lexer: multiple dedents" {
    var tok = lexer.Tokenizer.init("fn main =\n  if true\n    1\n2");
    try std.testing.expectEqual(lexer.Token.Tag.keyword_fn, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.identifier, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.newline, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.indent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_if, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.keyword_true, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.newline, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.indent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.newline, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.dedent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.dedent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
}

test "lexer: newline and indent" {
    var tok = lexer.Tokenizer.init("fn main =\n  42");
    try std.testing.expectEqual(lexer.Token.Tag.keyword_fn, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.identifier, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.newline, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.indent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
}

test "parser: placeholder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "package std.math\nimport std.core as core\nfn add x y = x + y\nlet answer = add 1 2\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 1), prog.imports.len);
    try std.testing.expectEqual(@as(usize, 3), prog.definitions.len);
    try std.testing.expect(prog.package != null);

    switch (prog.definitions[0]) {
        .package => {},
        else => return error.TestExpectedEqual,
    }

    const imp = prog.imports[0];
    try std.testing.expectEqualStrings("std", imp.path[0]);
    try std.testing.expectEqualStrings("core", imp.path[1]);

    switch (prog.definitions[1]) {
        .fn_def => |f| {
            try std.testing.expectEqualStrings("add", f.name);
            try std.testing.expectEqual(@as(usize, 2), f.params.len);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parser: record types and record syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "type Binding =\n  {\n    name : String,\n    value : Int\n  }\nlet binding = Binding { name = \"count\", value = 1 }\nmatch binding\n  Binding { name, .. } => name\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 3), prog.definitions.len);

    switch (prog.definitions[0]) {
        .type_def => |t| switch (t.body) {
            .record => |fields| try std.testing.expectEqual(@as(usize, 2), fields.len),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }

    switch (prog.definitions[1]) {
        .let_binding => |l| switch (l.value.*) {
            .record_literal => |r| {
                try std.testing.expectEqualStrings("Binding", r.name);
                try std.testing.expectEqual(@as(usize, 2), r.fields.len);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }

    switch (prog.definitions[2]) {
        .fn_def => |f| switch (f.body.*) {
            .match_expr => |m| {
                try std.testing.expectEqual(@as(usize, 1), m.arms.len);
                switch (m.arms[0].pattern) {
                    .record => |r| {
                        try std.testing.expectEqualStrings("Binding", r.name);
                        try std.testing.expect(r.rest);
                        try std.testing.expectEqual(@as(usize, 1), r.fields.len);
                    },
                    else => return error.TestExpectedEqual,
                }
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "parser: pipe and named args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "let out = input |> normalize ~mode:\"fast\"\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 1), prog.definitions.len);

    switch (prog.definitions[0]) {
        .let_binding => |l| switch (l.value.*) {
            .fn_call => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.args.len);
                try std.testing.expectEqual(@as(usize, 1), call.named_args.len);
                switch (call.func.*) {
                    .identifier => |name| try std.testing.expectEqualStrings("normalize", name),
                    else => return error.TestExpectedEqual,
                }
                try std.testing.expectEqualStrings("mode", call.named_args[0].name);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "typechecker: infer simple program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn add x y = x + y\nlet answer = add 1 2\nlet id = \\x -> x\nlet truth = id true\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    try std.testing.expect(infer.global.getScheme("add") != null);
    try std.testing.expect(infer.global.getScheme("answer") != null);
    try std.testing.expect(infer.global.getScheme("id") != null);
    try std.testing.expect(infer.global.getScheme("truth") != null);

    // Verify answer has type int
    const answer_scheme = infer.global.getScheme("answer").?;
    const answer_ty = infer.resolve(answer_scheme.body);
    try std.testing.expect(answer_ty.* == .int);

    // Verify truth has type bool
    const truth_scheme = infer.global.getScheme("truth").?;
    const truth_ty = infer.resolve(truth_scheme.body);
    try std.testing.expect(truth_ty.* == .bool);
}

test "typechecker: type mismatch detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // add true 1 should fail: true + 1 is ill-typed
    const source = try allocator.dupeZ(u8,
        "fn add x y = x + y\nlet bad = add true 1\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    const result = infer.inferProgram(&prog);
    try std.testing.expectError(error.TypeMismatch, result);
}

test "typechecker: ref creates Ref type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn make_ref _ =\n    ref 0\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const scheme = infer.global.getScheme("make_ref").?;
    const ty = infer.resolve(scheme.body);
    try std.testing.expect(ty.* == .arrow);
    const to = infer.resolve(ty.arrow.to);
    try std.testing.expect(to.* == .@"ref");
    try std.testing.expect(to.@"ref".* == .int);
}

test "typechecker: deref extracts Ref inner type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn get_val r =\n    !r\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const scheme = infer.global.getScheme("get_val").?;
    const ty = infer.resolve(scheme.body);
    try std.testing.expect(ty.* == .arrow);
    const from = infer.resolve(ty.arrow.from);
    try std.testing.expect(from.* == .@"ref");
    const to = infer.resolve(ty.arrow.to);
    try std.testing.expect(to.* == .variable);
}

test "typechecker: ref and deref round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn bump r =\n    r := !r + 1\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);
}

test "typechecker: let-polymorphism" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // id should be usable at both int and bool types
    const source = try allocator.dupeZ(u8,
        "let id = \\x -> x\nlet a = id 1\nlet b = id true\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const a_scheme = infer.global.getScheme("a").?;
    const a_ty = infer.resolve(a_scheme.body);
    try std.testing.expect(a_ty.* == .int);

    const b_scheme = infer.global.getScheme("b").?;
    const b_ty = infer.resolve(b_scheme.body);
    try std.testing.expect(b_ty.* == .bool);
}

test "typechecker: record literal type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "type Point = { x: Int, y: Int }\nlet p = Point { x = 1, y = 2 }\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const scheme = infer.global.getScheme("p").?;
    const ty = infer.resolve(scheme.body);
    try std.testing.expect(ty.* == .record);
    try std.testing.expectEqualStrings("Point", ty.record.name);
    try std.testing.expectEqual(@as(usize, 2), ty.record.fields.len);
}

test "typechecker: match arms consistent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "type Bool = True | False\nfn negate b =\n    match b\n        True => False\n        False => True\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const scheme = infer.global.getScheme("negate").?;
    const ty = infer.resolve(scheme.body);
    try std.testing.expect(ty.* == .arrow);
    const from = infer.resolve(ty.arrow.from);
    const to = infer.resolve(ty.arrow.to);
    try std.testing.expect(from.* == .con);
    try std.testing.expectEqualStrings("Bool", from.con.name);
    try std.testing.expect(to.* == .con);
    try std.testing.expectEqualStrings("Bool", to.con.name);
}

test "typechecker: match arm type mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "type Bool = True | False\nfn bad_fn b =\n    match b\n        True => 1\n        False => true\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    const result = infer.inferProgram(&prog);
    try std.testing.expectError(error.TypeMismatch, result);
}

test "typechecker: type annotation on let" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn get_val _ =\n    let x : Int = 42\n    x\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const scheme = infer.global.getScheme("get_val").?;
    const ty = infer.resolve(scheme.body);
    try std.testing.expect(ty.* == .arrow);
    const to = infer.resolve(ty.arrow.to);
    try std.testing.expect(to.* == .int);
}

test "typechecker: type annotation mismatch on let" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test that type mismatch is detected in binary ops
    const source = try allocator.dupeZ(u8,
        "fn bad_fn _ =\n    true + 1\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    const result = infer.inferProgram(&prog);
    try std.testing.expectError(error.TypeMismatch, result);
}

test "typechecker: type annotation on fn return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn double x : Int = x + x\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);

    const scheme = infer.global.getScheme("double").?;
    const ty = infer.resolve(scheme.body);
    // fn double x : Int = x + x
    // x has type annotation Int, body x+x is Int
    // so double : Int -> Int
    try std.testing.expect(ty.* == .arrow);
    const from = infer.resolve(ty.arrow.from);
    const to = infer.resolve(ty.arrow.to);
    try std.testing.expect(from.* == .int);
    try std.testing.expect(to.* == .int);
}

test "parser: ref and assign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "let counter = ref 0\ncounter := !counter + 1\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 2), prog.definitions.len);

    // ref 0
    switch (prog.definitions[0]) {
        .let_binding => |l| switch (l.value.*) {
            .ref_expr => |inner| switch (inner.*) {
                .int_literal => |v| try std.testing.expectEqual(@as(i64, 0), v),
                else => return error.TestExpectedEqual,
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }

    // counter := ...
    switch (prog.definitions[1]) {
        .fn_def => |f| switch (f.body.*) {
            .assign_expr => |a| {
                switch (a.target.*) {
                    .identifier => |name| try std.testing.expectEqualStrings("counter", name),
                    else => return error.TestExpectedEqual,
                }
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "parser: type annotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "fn add x y = x + y\nlet answer : Int = add 1 2\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 2), prog.definitions.len);

    // fn add x y - no type annotation
    switch (prog.definitions[0]) {
        .fn_def => |f| {
            try std.testing.expectEqualStrings("add", f.name);
            try std.testing.expectEqual(@as(usize, 2), f.params.len);
            try std.testing.expect(f.return_type == null);
        },
        else => return error.TestExpectedEqual,
    }

    // let answer : Int = ...
    switch (prog.definitions[1]) {
        .let_binding => |l| {
            try std.testing.expectEqualStrings("answer", l.name);
            try std.testing.expect(l.type_ann != null);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parser: module with indent block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "module Math\n  pub fn add x y = x + y\n  pub fn mul x y = x * y\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 1), prog.definitions.len);

    switch (prog.definitions[0]) {
        .module_def => |m| {
            try std.testing.expectEqualStrings("Math", m.name);
            try std.testing.expectEqual(@as(usize, 2), m.definitions.len);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parser: selective import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "import std.math.{PI, E}\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 1), prog.imports.len);

    const imp = prog.imports[0];
    try std.testing.expectEqualStrings("std", imp.path[0]);
    try std.testing.expectEqualStrings("math", imp.path[1]);
    try std.testing.expect(imp.selective != null);
    try std.testing.expectEqual(@as(usize, 2), imp.selective.?.len);
    try std.testing.expectEqualStrings("PI", imp.selective.?[0]);
    try std.testing.expectEqualStrings("E", imp.selective.?[1]);
}

test "parser: constructor with type params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "type List a = Cons a (List a) | Nil\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 1), prog.definitions.len);

    switch (prog.definitions[0]) {
        .type_def => |t| {
            try std.testing.expectEqualStrings("List", t.name);
            try std.testing.expectEqual(@as(usize, 1), t.type_params.len);
            try std.testing.expectEqualStrings("a", t.type_params[0]);
            switch (t.body) {
                .sum => |ctors| {
                    try std.testing.expectEqual(@as(usize, 2), ctors.len);
                    try std.testing.expectEqualStrings("Cons", ctors[0].name);
                    try std.testing.expectEqual(@as(usize, 2), ctors[0].params.len);
                    try std.testing.expectEqualStrings("Nil", ctors[1].name);
                    try std.testing.expectEqual(@as(usize, 0), ctors[1].params.len);
                },
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "parser: lambda with pattern params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "let f = \\x y -> x + y\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();

    const prog = try p.parse_program();
    try std.testing.expectEqual(@as(usize, 1), prog.definitions.len);

    switch (prog.definitions[0]) {
        .let_binding => |l| switch (l.value.*) {
            .lambda => |lam| {
                try std.testing.expectEqual(@as(usize, 2), lam.params.len);
                switch (lam.params[0]) {
                    .identifier => |name| try std.testing.expectEqualStrings("x", name),
                    else => return error.TestExpectedEqual,
                }
                switch (lam.params[1]) {
                    .identifier => |name| try std.testing.expectEqualStrings("y", name),
                    else => return error.TestExpectedEqual,
                }
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
}

test "lexer: ref and colon_equal tokens" {
    var tok = lexer.Tokenizer.init("ref x := 5");
    try std.testing.expectEqual(lexer.Token.Tag.keyword_ref, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.identifier, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.colon_equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
}

test "typecheck: tuple pattern in fn param" {
    try typecheck.testInfer(
        \\fn fst (a, b) =
        \\    a
    );
}

test "typecheck: constructor pattern in fn param" {
    try typecheck.testInfer(
        \\type Option a = Some a | None
        \\fn unwrap opt =
        \\    match opt
        \\        Some x => x
        \\        None => 0
    );
}

test "typecheck: ref creates Ref type" {
    try typecheck.testInfer(
        \\fn f x =
        \\    ref x
    );
}

test "typecheck: deref extracts inner type" {
    try typecheck.testInfer(
        \\fn f r =
        \\    !r
    );
}

test "typecheck: ref/deref round-trip" {
    try typecheck.testInfer(
        \\fn f x =
        \\    !(ref x)
    );
}

test "typecheck: let-polymorphism" {
    try typecheck.testInfer(
        \\fn f x =
        \\    let id = \y -> y
        \\    (id 1, id true)
    );
}

test "typecheck: record literal type" {
    try typecheck.testInfer(
        \\type Pos = {x: Int, y: Int}
        \\fn f x =
        \\    Pos {x = 1, y = 2}
    );
}

test "typecheck: match arms consistent" {
    try typecheck.testInfer(
        \\type Bool = True | False
        \\fn f b =
        \\    match b
        \\        True => 1
        \\        False => 0
    );
}

test "typecheck: match arm type mismatch" {
    const result = typecheck.testInfer(
        \\type Bool = True | False
        \\fn f b =
        \\    match b
        \\        True => 1
        \\        False => true
    );
    try std.testing.expectError(error.TypeMismatch, result);
}

test "typecheck: type annotation on let" {
    try typecheck.testInfer(
        \\fn f x =
        \\    let y : Int = 5
        \\    y
    );
}

test "typecheck: type annotation mismatch on let" {
    const result = typecheck.testInfer(
        \\fn f x =
        \\    let y : Bool = 5
        \\    y
    );
    try std.testing.expectError(error.TypeMismatch, result);
}

test "typecheck: type annotation on fn return" {
    try typecheck.testInfer(
        \\fn f : Int = 42
    );
}

test "integration: basic arithmetic" {
    try typecheck.testInfer(
        \\fn add x y = x + y
        \\fn square x = x * x
        \\fn abs x =
        \\    if x < 0
        \\        0 - x
        \\    else
        \\        x
    );
}

test "integration: string operations" {
    try typecheck.testInfer(
        \\fn greet name = "hello " + name
        \\fn length s = s.length
    );
}

test "integration: if expression" {
    try typecheck.testInfer(
        \\fn max x y =
        \\    if x > y
        \\        x
        \\    else
        \\        y
    );
}

test "integration: nested if" {
    try typecheck.testInfer(
        \\fn classify x =
        \\    if x < 0
        \\        "negative"
        \\    else if x == 0
        \\        "zero"
        \\    else
        \\        "positive"
    );
}

test "integration: let binding" {
    try typecheck.testInfer(
        \\fn f x =
        \\    let double = x + x
        \\    let quadruple = double + double
        \\    quadruple
    );
}

test "integration: let with type annotation" {
    try typecheck.testInfer(
        \\fn f x =
        \\    let y : Int = x + 1
        \\    let z : Int = y * 2
        \\    z
    );
}

test "integration: lambda and higher-order" {
    try typecheck.testInfer(
        \\fn apply f x = f x
        \\fn compose f g x = f (g x)
        \\fn twice f x = f (f x)
    );
}

test "integration: lambda in expression" {
    try typecheck.testInfer(
        \\fn apply_to_five f = f 5
    );
}

test "integration: sum type definition and constructors" {
    try typecheck.testInfer(
        \\type Bool = True | False
        \\fn negate b =
        \\    match b
        \\        True => False
        \\        False => True
    );
}

test "integration: sum type with params" {
    try typecheck.testInfer(
        \\type Option a = Some a | None
        \\fn from_optional x =
        \\    match x
        \\        Some v => v
        \\        None => 0
    );
}

test "integration: nested sum types" {
    try typecheck.testInfer(
        \\type List a = Cons a (List a) | Nil
        \\fn head lst =
        \\    match lst
        \\        Cons x _ => x
        \\        Nil => 0
    );
}

test "integration: record type and literal" {
    try typecheck.testInfer(
        \\type Point = {x: Int, y: Int}
        \\fn make_point x y = Point {x = x, y = y}
        \\fn get_x p = p.x
    );
}

test "integration: record pattern matching" {
    try typecheck.testInfer(
        \\type Point = {x: Int, y: Int}
        \\fn distance p =
        \\    match p
        \\        Point {x, y} => x + y
    );
}

test "integration: ref and mutation" {
    try typecheck.testInfer(
        \\fn make_counter x =
        \\    let counter = ref x
        \\    counter := !counter + 1
        \\    !counter
    );
}

test "integration: multiple refs" {
    try typecheck.testInfer(
        \\fn swap a b =
        \\    let temp = !a
        \\    a := !b
        \\    b := temp
    );
}

test "integration: mutual recursion via let" {
    try typecheck.testInfer(
        \\type Bool = True | False
        \\fn is_even n =
        \\    if n == 0
        \\        True
        \\    else
        \\        is_odd (n - 1)
        \\fn is_odd n =
        \\    if n == 0
        \\        False
        \\    else
        \\        is_even (n - 1)
    );
}

test "integration: complex pattern matching" {
    try typecheck.testInfer(
        \\type Expr = Num Int | Add Expr Expr | Mul Expr Expr
        \\fn eval e =
        \\    match e
        \\        Num n => n
        \\        Add a b => eval a + eval b
        \\        Mul a b => eval a * eval b
    );
}

test "integration: pipe operator" {
    try typecheck.testInfer(
        \\fn add_one x = x + 1
        \\fn double x = x * 2
        \\fn pipeline x = x |> add_one |> double
    );
}

test "integration: comptime" {
    try typecheck.testInfer(
        \\comptime fn constexpr_add x y = x + y
    );
}

test "integration: full program with main" {
    try typecheck.testInfer(
        \\type Option a = Some a | None
        \\type Result = {ok: Bool, value: Int}
        \\pub fn main =
        \\    let x : Int = 42
        \\    let opt = Some x
        \\    match opt
        \\        Some v => v
        \\        None => 0
    );
}
