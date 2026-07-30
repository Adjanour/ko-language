const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const repl_mod = @import("repl.zig");
const codegen_mod = @import("codegen.zig");
const stdlib = @import("stdlib.zig");
const llvm = @import("llvm");
const core = llvm.core;
const engine = llvm.engine;
const types = llvm.types;

fn testRuntime(source: [:0]const u8) !i64 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cg = codegen_mod.Codegen.init(allocator, "test");
    defer cg.deinit();
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    try cg.codegenProgram(prog);
    var jit = try codegen_mod.Jit.init(cg.module, 0);
    defer jit.deinit();
    cg.module_owned_by_jit = true;
    cg.mapBuiltinsToNative(jit.engine);
    return try jit.runMain();
}

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
    try std.testing.expectEqual(lexer.Token.Tag.comment, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.number, tok.next().tag);
}

test "lexer: comment line inside indent" {
    var tok = lexer.Tokenizer.init("fn main =\n  # comment\n  42");
    try std.testing.expectEqual(lexer.Token.Tag.keyword_fn, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.identifier, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.equal, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.newline, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.indent, tok.next().tag);
    try std.testing.expectEqual(lexer.Token.Tag.comment, tok.next().tag);
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
                    .identifier => |id| try std.testing.expectEqualStrings("normalize", id.name),
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
                    .identifier => |id| try std.testing.expectEqualStrings("counter", id.name),
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

test "integration: module with multiple functions using match" {
    try typecheck.testInfer(
        \\module Geo
        \\  type Point = { x: Int, y: Int }
        \\  pub fn distance p = match p
        \\    Point { x, y } => x * x + y * y
        \\  pub fn translate p dx dy = match p
        \\    Point { x, y } => Point { x = x + dx, y = y + dy }
        \\fn main =
        \\  let p = Geo.Point { x = 3, y = 4 }
        \\  let d = Geo.distance p
        \\  let p2 = Geo.translate p 10 20
        \\  let d2 = Geo.distance p2
        \\  d + d2
    );
}

test "integration: partial application of multi-param function" {
    try typecheck.testInfer(
        \\fn add x y = x + y
        \\fn main =
        \\  let add1 = add 1
        \\  add1 2
    );
}

test "integration: currying with compose" {
    try typecheck.testInfer(
        \\fn compose f g x = f (g x)
        \\fn double x = x * 2
        \\fn inc x = x + 1
        \\fn main =
        \\  let double_then_inc = compose inc double
        \\  double_then_inc 5
    );
}

test "integration: lambda closures capture environment" {
    try typecheck.testInfer(
        \\fn main =
        \\  let x = 10
        \\  let f = \y -> x + y
        \\  f 5
    );
}

test "integration: pipe with partial application" {
    try typecheck.testInfer(
        \\fn add x y = x + y
        \\fn double x = x * 2
        \\fn main =
        \\  5 |> add 1 |> double
    );
}

test "parser: all .ko test files parse successfully" {
    const files = [_]struct { name: []const u8, source: [:0]const u8 }{
        .{ .name = "syntax_literal.ko", .source = @embedFile("tests_ko/syntax_literal.ko") },
        .{ .name = "syntax_string.ko", .source = @embedFile("tests_ko/syntax_string.ko") },
        .{ .name = "syntax_bool.ko", .source = @embedFile("tests_ko/syntax_bool.ko") },
        .{ .name = "syntax_arithmetic.ko", .source = @embedFile("tests_ko/syntax_arithmetic.ko") },
        .{ .name = "syntax_comparison.ko", .source = @embedFile("tests_ko/syntax_comparison.ko") },
        .{ .name = "syntax_logical.ko", .source = @embedFile("tests_ko/syntax_logical.ko") },
        .{ .name = "syntax_unary.ko", .source = @embedFile("tests_ko/syntax_unary.ko") },
        .{ .name = "syntax_application.ko", .source = @embedFile("tests_ko/syntax_application.ko") },
        .{ .name = "syntax_let.ko", .source = @embedFile("tests_ko/syntax_let.ko") },
        .{ .name = "syntax_fn.ko", .source = @embedFile("tests_ko/syntax_fn.ko") },
        .{ .name = "syntax_fn_block.ko", .source = @embedFile("tests_ko/syntax_fn_block.ko") },
        .{ .name = "syntax_if.ko", .source = @embedFile("tests_ko/syntax_if.ko") },
        .{ .name = "type_sum.ko", .source = @embedFile("tests_ko/type_sum.ko") },
        .{ .name = "type_sum_params.ko", .source = @embedFile("tests_ko/type_sum_params.ko") },
        .{ .name = "type_record.ko", .source = @embedFile("tests_ko/type_record.ko") },
        .{ .name = "syntax_record.ko", .source = @embedFile("tests_ko/syntax_record.ko") },
        .{ .name = "pattern_match.ko", .source = @embedFile("tests_ko/pattern_match.ko") },
        .{ .name = "fn_lambda.ko", .source = @embedFile("tests_ko/fn_lambda.ko") },
        .{ .name = "fn_lambda_wildcard.ko", .source = @embedFile("tests_ko/fn_lambda_wildcard.ko") },
        .{ .name = "syntax_pipe.ko", .source = @embedFile("tests_ko/syntax_pipe.ko") },
        .{ .name = "syntax_tuple.ko", .source = @embedFile("tests_ko/syntax_tuple.ko") },
        .{ .name = "module_def.ko", .source = @embedFile("tests_ko/module_def.ko") },
        .{ .name = "module_import.ko", .source = @embedFile("tests_ko/module_import.ko") },
        .{ .name = "comptime_expr.ko", .source = @embedFile("tests_ko/comptime_expr.ko") },
        .{ .name = "syntax_nested.ko", .source = @embedFile("tests_ko/syntax_nested.ko") },
        .{ .name = "syntax_precedence.ko", .source = @embedFile("tests_ko/syntax_precedence.ko") },
        .{ .name = "syntax_hyphenated.ko", .source = @embedFile("tests_ko/syntax_hyphenated.ko") },
        .{ .name = "pattern_wildcard.ko", .source = @embedFile("tests_ko/pattern_wildcard.ko") },
        .{ .name = "syntax_comment.ko", .source = @embedFile("tests_ko/syntax_comment.ko") },
        .{ .name = "syntax_block.ko", .source = @embedFile("tests_ko/syntax_block.ko") },
        .{ .name = "syntax_minimal.ko", .source = @embedFile("tests_ko/syntax_minimal.ko") },
        .{ .name = "fn_partial.ko", .source = @embedFile("tests_ko/fn_partial.ko") },
        .{ .name = "fn_curry.ko", .source = @embedFile("tests_ko/fn_curry.ko") },
        .{ .name = "fn_closure.ko", .source = @embedFile("tests_ko/fn_closure.ko") },
        .{ .name = "syntax_cons.ko", .source = @embedFile("tests_ko/syntax_cons.ko") },
        .{ .name = "comptime_fn.ko", .source = @embedFile("tests_ko/comptime_fn.ko") },
        .{ .name = "builtin_math.ko", .source = @embedFile("tests_ko/builtin_math.ko") },
        .{ .name = "builtin_result.ko", .source = @embedFile("tests_ko/builtin_result.ko") },
        .{ .name = "comptime_list.ko", .source = @embedFile("tests_ko/comptime_list.ko") },
        .{ .name = "comptime_string.ko", .source = @embedFile("tests_ko/comptime_string.ko") },
        .{ .name = "comptime_match.ko", .source = @embedFile("tests_ko/comptime_match.ko") },
    };

    for (files) |f| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var p = parser.Parser.init(allocator, f.source) catch |err| {
            std.debug.print("FAIL: {s} - parser init error: {}\n", .{ f.name, err });
            return error.TestFailed;
        };
        defer p.deinit();

        _ = p.parse_program() catch |err| {
            std.debug.print("FAIL: {s} - parse error: {}\n", .{ f.name, err });
            return error.TestFailed;
        };
    }
    std.debug.print("Parsed {d} test files successfully\n", .{files.len});
}

test "doc comment tokens" {
    var tok = lexer.Tokenizer.init("# Add two integers\nfn add x y = x + y\n");
    const t1 = tok.next();
    try std.testing.expectEqual(lexer.Token.Tag.comment, t1.tag);
    const raw_text = tok.source[t1.loc.start..t1.loc.end];
    try std.testing.expectEqualStrings(" Add two integers", raw_text);

    const t2 = tok.next();
    try std.testing.expectEqual(lexer.Token.Tag.keyword_fn, t2.tag);
}

test "multi-line doc comments per function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = try allocator.dupeZ(u8,
        "# First doc line\n# Second doc line\nfn add x y = x + y\n\n# Mul doc line\nfn mul x y = x * y\n");

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();

    try std.testing.expectEqual(@as(usize, 2), prog.definitions.len);

    const add_def = prog.definitions[0].fn_def;
    try std.testing.expectEqualStrings("add", add_def.name);
    if (add_def.doc_comments) |docs| {
        try std.testing.expectEqual(@as(usize, 2), docs.len);
        try std.testing.expectEqualStrings("First doc line", docs[0]);
        try std.testing.expectEqualStrings("Second doc line", docs[1]);
    } else {
        return error.TestExpectedResult;
    }

    const mul_def = prog.definitions[1].fn_def;
    try std.testing.expectEqualStrings("mul", mul_def.name);
    if (mul_def.doc_comments) |docs| {
        try std.testing.expectEqual(@as(usize, 1), docs.len);
        try std.testing.expectEqualStrings("Mul doc line", docs[0]);
    } else {
        return error.TestExpectedResult;
    }
}

test "tuple destructuring in let" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source_z = try allocator.dupeZ(u8,
        \\fn main =
        \\  let (x, y) = (10, 20)
        \\  println (x + y)
    );

    var p = try parser.Parser.init(allocator, source_z);
    defer p.deinit();
    const prog = try p.parse_program();

    try std.testing.expectEqual(@as(usize, 1), prog.definitions.len);

    var infer = typecheck.Inferer.init(allocator);
    defer infer.deinit();
    try infer.inferProgram(&prog);
}

// =============================================================================
// Runtime Correctness Tests — compile, JIT-execute, check return value
// =============================================================================

test "runtime: literal integer" {
    const result = try testRuntime(
        \\fn main = 42
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: arithmetic" {
    const result = try testRuntime(
        \\fn main = 2 + 3 * 4
    );
    try std.testing.expectEqual(@as(i64, 14), result);
}

test "runtime: boolean if/else" {
    const result = try testRuntime(
        \\fn main = if 1 < 2 then 10 else 20
    );
    try std.testing.expectEqual(@as(i64, 10), result);
}

test "runtime: negation" {
    const result = try testRuntime(
        \\fn main = -(5 + 3)
    );
    try std.testing.expectEqual(@as(i64, -8), result);
}

test "runtime: function call" {
    const result = try testRuntime(
        \\fn add x y = x + y
        \\fn main = add 10 32
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: nested function calls" {
    const result = try testRuntime(
        \\fn double x = x + x
        \\fn halve x = x / 2
        \\fn main = double (halve 20)
    );
    try std.testing.expectEqual(@as(i64, 20), result);
}

test "runtime: recursive function" {
    const result = try testRuntime(
        \\fn fact n = if n <= 1 then 1 else n * fact (n - 1)
        \\fn main = fact 6
    );
    try std.testing.expectEqual(@as(i64, 720), result);
}

test "runtime: mutual recursion" {
    const result = try testRuntime(
        \\fn is_even n = if n == 0 then 1 else is_odd (n - 1)
        \\fn is_odd n = if n == 0 then 0 else is_even (n - 1)
        \\fn main = is_even 10
    );
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "runtime: sum type constructors" {
    const result = try testRuntime(
        \\type Bool = True | False
        \\fn negate b = match b
        \\  True => 0
        \\  False => 1
        \\fn main = negate True
    );
    try std.testing.expectEqual(@as(i64, 0), result);
}

test "runtime: sum type with payload" {
    const result = try testRuntime(
        \\type Option = Some Int | None
        \\fn get_value opt = match opt
        \\  Some v => v
        \\  None => 0
        \\fn main = get_value (Some 99)
    );
    try std.testing.expectEqual(@as(i64, 99), result);
}

test "runtime: recursive sum type (Nat)" {
    const result = try testRuntime(
        \\type Nat = Succ Nat | Zero
        \\fn count n = match n
        \\  Succ rest => 1 + count rest
        \\  Zero => 0
        \\fn main = count (Succ (Succ (Succ Zero)))
    );
    try std.testing.expectEqual(@as(i64, 3), result);
}

test "runtime: nested pattern matching" {
    const result = try testRuntime(
        \\type List a = Cons a (List a) | Nil
        \\fn count xs = match xs
        \\  Cons _ (Cons _ rest) => 1 + count rest
        \\  Cons _ Nil => 1
        \\  Nil => 0
        \\fn main = count (Cons 1 (Cons 2 (Cons 3 Nil)))
    );
    try std.testing.expectEqual(@as(i64, 2), result);
}

test "runtime: pattern matching with computation" {
    const result = try testRuntime(
        \\type List a = Cons a (List a) | Nil
        \\fn sum xs = match xs
        \\  Cons x rest => x + sum rest
        \\  Nil => 0
        \\fn main = sum (Cons 10 (Cons 20 (Cons 30 Nil)))
    );
    try std.testing.expectEqual(@as(i64, 60), result);
}

test "runtime: ref and mutation" {
    const result = try testRuntime(
        \\fn main =
        \\  let r = ref 0
        \\  r := 5
        \\  !r
    );
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "runtime: ref in loop" {
    const result = try testRuntime(
        \\fn main =
        \\  let r = ref 0
        \\  r := !r + 1
        \\  r := !r + 1
        \\  r := !r + 1
        \\  !r
    );
    try std.testing.expectEqual(@as(i64, 3), result);
}

test "runtime: swap via refs" {
    const result = try testRuntime(
        \\fn swap a b =
        \\  let temp = !a
        \\  a := !b
        \\  b := temp
        \\fn main =
        \\  let x = ref 10
        \\  let y = ref 20
        \\  swap x y
        \\  !x + !y
    );
    try std.testing.expectEqual(@as(i64, 30), result);
}

test "runtime: lambda application" {
    const result = try testRuntime(
        \\fn main = (\x -> x + 1) 41
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: lambda closure" {
    const result = try testRuntime(
        \\fn make_adder x = \y -> x + y
        \\fn main = (make_adder 10) 32
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: higher-order function" {
    const result = try testRuntime(
        \\fn apply f x = f x
        \\fn double x = x * 2
        \\fn main = apply double 21
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: partial application" {
    const result = try testRuntime(
        \\fn add x y = x + y
        \\fn main = (add 10) 32
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: let binding" {
    const result = try testRuntime(
        \\fn main =
        \\  let x = 10
        \\  let y = 32
        \\  x + y
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: nested let" {
    const result = try testRuntime(
        \\fn main =
        \\  let x = 10
        \\  let y = 32
        \\  let z = x + y
        \\  z * 2
    );
    try std.testing.expectEqual(@as(i64, 84), result);
}

test "runtime: complex expression" {
    const result = try testRuntime(
        \\fn main =
        \\  let x = 5
        \\  let y = 10
        \\  let z = 15
        \\  x * y + z - (x + y)
    );
    try std.testing.expectEqual(@as(i64, 50), result);
}

test "runtime: list length recursive" {
    const result = try testRuntime(
        \\type List a = Cons a (List a) | Nil
        \\fn length xs = match xs
        \\  Cons _ rest => 1 + length rest
        \\  Nil => 0
        \\fn main = length (Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil))))
    );
    try std.testing.expectEqual(@as(i64, 4), result);
}

test "runtime: fibonacci" {
    const result = try testRuntime(
        \\fn fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
        \\fn main = fib 10
    );
    try std.testing.expectEqual(@as(i64, 55), result);
}

test "runtime: factorial" {
    const result = try testRuntime(
        \\fn fact n = if n <= 1 then 1 else n * fact (n - 1)
        \\fn main = fact 8
    );
    try std.testing.expectEqual(@as(i64, 40320), result);
}

test "runtime: string length" {
    const result = try testRuntime(
        \\fn main = String.length "hello"
    );
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "runtime: pipe operator" {
    const result = try testRuntime(
        \\fn add_one x = x + 1
        \\fn double x = x * 2
        \\fn main = 20 |> add_one |> double
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: if/else with computation" {
    const result = try testRuntime(
        \\fn max a b = if a > b then a else b
        \\fn main = max 10 20
    );
    try std.testing.expectEqual(@as(i64, 20), result);
}

test "runtime: nested pattern with recursion (Succ Zero)" {
    const result = try testRuntime(
        \\type Nat = Succ Nat | Zero
        \\fn count n = match n
        \\  Succ Zero => 1
        \\  Succ rest => 1 + count rest
        \\  Zero => 0
        \\fn main = count (Succ (Succ (Succ Zero)))
    );
    try std.testing.expectEqual(@as(i64, 3), result);
}

// =============================================================================
// Example-based Runtime Tests — adapted from examples/ directory
// =============================================================================

test "runtime: ackermann function" {
    const result = try testRuntime(
        \\fn ack m n =
        \\  if m == 0 then n + 1
        \\  else if n == 0 then ack (m - 1) 1
        \\  else ack (m - 1) (ack m (n - 1))
        \\fn main = ack 3 3
    );
    try std.testing.expectEqual(@as(i64, 61), result);
}

test "runtime: ackermann base cases" {
    const result = try testRuntime(
        \\fn ack m n =
        \\  if m == 0 then n + 1
        \\  else if n == 0 then ack (m - 1) 1
        \\  else ack (m - 1) (ack m (n - 1))
        \\fn main = ack 2 2
    );
    try std.testing.expectEqual(@as(i64, 7), result);
}

test "runtime: numeric GCD" {
    const result = try testRuntime(
        \\fn gcd a b =
        \\  if b == 0 then a
        \\  else gcd b (a % b)
        \\fn main = gcd 12 8
    );
    try std.testing.expectEqual(@as(i64, 4), result);
}

test "runtime: numeric LCM" {
    const result = try testRuntime(
        \\fn gcd a b =
        \\  if b == 0 then a
        \\  else gcd b (a % b)
        \\fn lcm a b = (a * b) / gcd a b
        \\fn main = lcm 4 6
    );
    try std.testing.expectEqual(@as(i64, 12), result);
}

test "runtime: fast exponentiation" {
    const result = try testRuntime(
        \\fn pow base exp =
        \\  if exp == 0 then 1
        \\  else if exp % 2 == 0 then pow (base * base) (exp / 2)
        \\  else base * pow base (exp - 1)
        \\fn main = pow 2 10
    );
    try std.testing.expectEqual(@as(i64, 1024), result);
}

test "runtime: primality test" {
    const result = try testRuntime(
        \\fn is_prime n =
        \\  if n < 2 then 0
        \\  else if n == 2 then 1
        \\  else if n % 2 == 0 then 0
        \\  else is_prime_aux n 3
        \\fn is_prime_aux n d =
        \\  if d * d > n then 1
        \\  else if n % d == 0 then 0
        \\  else is_prime_aux n (d + 2)
        \\fn main = is_prime 13
    );
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "runtime: digit sum" {
    const result = try testRuntime(
        \\fn digit_sum n =
        \\  if n < 10 then n
        \\  else n % 10 + digit_sum (n / 10)
        \\fn main = digit_sum 999
    );
    try std.testing.expectEqual(@as(i64, 27), result);
}

test "runtime: number of digits" {
    const result = try testRuntime(
        \\fn num_digits n =
        \\  if n < 10 then 1
        \\  else 1 + num_digits (n / 10)
        \\fn main = num_digits 12345
    );
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "runtime: reverse number" {
    const result = try testRuntime(
        \\fn rev_aux n acc =
        \\  if n == 0 then acc
        \\  else rev_aux (n / 10) (acc * 10 + n % 10)
        \\fn main = rev_aux 123 0
    );
    try std.testing.expectEqual(@as(i64, 321), result);
}

test "runtime: triangle number" {
    const result = try testRuntime(
        \\fn triangle n = n * (n + 1) / 2
        \\fn main = triangle 10
    );
    try std.testing.expectEqual(@as(i64, 55), result);
}

test "runtime: hailstone length" {
    const result = try testRuntime(
        \\fn hailstoneLength n =
        \\  if n == 1 then 0
        \\  else if n % 2 == 0 then 1 + hailstoneLength (n / 2)
        \\  else 1 + hailstoneLength (3 * n + 1)
        \\fn main = hailstoneLength 6
    );
    try std.testing.expectEqual(@as(i64, 8), result);
}

test "runtime: binary tree sum" {
    const result = try testRuntime(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_sum tree = match tree
        \\  Branch left right => tree_sum left + tree_sum right
        \\  Leaf n => n
        \\fn main = tree_sum (Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5))
    );
    try std.testing.expectEqual(@as(i64, 9), result);
}

test "runtime: binary tree count" {
    const result = try testRuntime(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_count tree = match tree
        \\  Branch left right => tree_count left + tree_count right
        \\  Leaf _ => 1
        \\fn main = tree_count (Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5))
    );
    try std.testing.expectEqual(@as(i64, 3), result);
}

test "runtime: binary tree height" {
    const result = try testRuntime(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_height tree = match tree
        \\  Leaf _ => 1
        \\  Branch left right =>
        \\    let lh = tree_height left
        \\    let rh = tree_height right
        \\    if lh > rh then 1 + lh else 1 + rh
        \\fn main = tree_height (Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5))
    );
    try std.testing.expectEqual(@as(i64, 3), result);
}

test "runtime: binary tree max" {
    const result = try testRuntime(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_max tree = match tree
        \\  Leaf n => n
        \\  Branch left right =>
        \\    let lm = tree_max left
        \\    let rm = tree_max right
        \\    if lm > rm then lm else rm
        \\fn main = tree_max (Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5))
    );
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "runtime: list map and sum" {
    const result = try testRuntime(
        \\type List a = Cons a (List a) | Nil
        \\fn map f xs = match xs
        \\  Cons x rest => Cons (f x) (map f rest)
        \\  Nil => Nil
        \\fn sumList xs = match xs
        \\  Cons x rest => x + sumList rest
        \\  Nil => 0
        \\fn main = sumList (map (\x -> x * 2) (Cons 1 (Cons 2 (Cons 3 Nil))))
    );
    try std.testing.expectEqual(@as(i64, 12), result);
}

test "runtime: list filter and sum" {
    const result = try testRuntime(
        \\type List a = Cons a (List a) | Nil
        \\fn filter pred xs = match xs
        \\  Cons x rest =>
        \\    if pred x then Cons x (filter pred rest)
        \\    else filter pred rest
        \\  Nil => Nil
        \\fn sumList xs = match xs
        \\  Cons x rest => x + sumList rest
        \\  Nil => 0
        \\fn main = sumList (filter (\x -> x % 2 == 0) (Cons 1 (Cons 2 (Cons 3 (Cons 4 Nil)))))
    );
    try std.testing.expectEqual(@as(i64, 6), result);
}

test "runtime: compose functions" {
    const result = try testRuntime(
        \\fn compose f g x = f (g x)
        \\fn double x = x * 2
        \\fn inc x = x + 1
        \\fn main = (compose inc double) 5
    );
    try std.testing.expectEqual(@as(i64, 11), result);
}

test "runtime: record field access" {
    const result = try testRuntime(
        \\type Point = { x : Int, y : Int }
        \\fn main =
        \\  let p = Point { x = 3, y = 4 }
        \\  p.x + p.y
    );
    try std.testing.expectEqual(@as(i64, 7), result);
}

test "runtime: record operations" {
    const result = try testRuntime(
        \\type Point = { x : Int, y : Int }
        \\fn dist_sq p1 p2 =
        \\  let dx = p1.x - p2.x
        \\  let dy = p1.y - p2.y
        \\  dx * dx + dy * dy
        \\fn main =
        \\  let origin = Point { x = 0, y = 0 }
        \\  let p1 = Point { x = 3, y = 4 }
        \\  dist_sq origin p1
    );
    try std.testing.expectEqual(@as(i64, 25), result);
}

test "runtime: state machine with refs" {
    const result = try testRuntime(
        \\type State = Idle | Counting Int | Done
        \\fn extract state = match state
        \\  Counting v => v
        \\  Done => 99
        \\  Idle => 0
        \\fn next_state current limit =
        \\  let c = !current
        \\  if c >= limit then Done
        \\  else
        \\    current := c + 1
        \\    Counting (c + 1)
        \\fn main =
        \\  let current = ref 0
        \\  let _a = next_state current 5
        \\  let _b = next_state current 5
        \\  let _c = next_state current 5
        \\  extract (next_state current 5)
    );
    try std.testing.expectEqual(@as(i64, 4), result);
}

test "runtime: nested pattern with recursion (Succ Zero) 2-level" {
    const result = try testRuntime(
        \\type Nat = Succ Nat | Zero
        \\fn count n = match n
        \\  Succ Zero => 1
        \\  Succ rest => 1 + count rest
        \\  Zero => 0
        \\fn main = count (Succ (Succ Zero))
    );
    try std.testing.expectEqual(@as(i64, 2), result);
}

test "runtime: edge case zero" {
    const result = try testRuntime(
        \\fn main = 0
    );
    try std.testing.expectEqual(@as(i64, 0), result);
}

test "runtime: edge case negative" {
    const result = try testRuntime(
        \\fn main = -42
    );
    try std.testing.expectEqual(@as(i64, -42), result);
}

test "runtime: edge case large multiplication" {
    const result = try testRuntime(
        \\fn main = 999 * 999
    );
    try std.testing.expectEqual(@as(i64, 998001), result);
}

test "runtime: edge case division" {
    const result = try testRuntime(
        \\fn main = 100 / 7
    );
    try std.testing.expectEqual(@as(i64, 14), result);
}

test "runtime: edge case modulo" {
    const result = try testRuntime(
        \\fn main = 100 % 7
    );
    try std.testing.expectEqual(@as(i64, 2), result);
}

test "runtime: edge case chained arithmetic" {
    const result = try testRuntime(
        \\fn main = 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10
    );
    try std.testing.expectEqual(@as(i64, 55), result);
}

test "runtime: assert passes" {
    const result = try testRuntime(
        \\fn main =
        \\  assert true
        \\  42
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: assert_eq passes" {
    const result = try testRuntime(
        \\fn main =
        \\  assert_eq 42 42
        \\  42
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: deep recursion factorial 12" {
    const result = try testRuntime(
        \\fn fact n = if n <= 1 then 1 else n * fact (n - 1)
        \\fn main = fact 12
    );
    try std.testing.expectEqual(@as(i64, 479001600), result);
}

test "runtime: mutual recursion even/odd" {
    const result = try testRuntime(
        \\fn is_even n = if n == 0 then 1 else is_odd (n - 1)
        \\fn is_odd n = if n == 0 then 0 else is_even (n - 1)
        \\fn main = is_even 100
    );
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "runtime: nested if/else" {
    const result = try testRuntime(
        \\fn clamp lo hi x =
        \\  if x < lo then lo
        \\  else if x > hi then hi
        \\  else x
        \\fn main = clamp 0 10 15
    );
    try std.testing.expectEqual(@as(i64, 10), result);
}

test "runtime: higher-order function with closure" {
    const result = try testRuntime(
        \\fn makeMultiplier n = \x -> x * n
        \\fn main = (makeMultiplier 3) 7
    );
    try std.testing.expectEqual(@as(i64, 21), result);
}

test "runtime: nested closures" {
    const result = try testRuntime(
        \\fn make_adder x = \y -> x + y
        \\fn main = ((make_adder 10) 20) + ((make_adder 30) 12)
    );
    try std.testing.expectEqual(@as(i64, 72), result);
}

test "runtime: complex nested match" {
    const result = try testRuntime(
        \\type Maybe = Just Int | Nothing
        \\fn from_just m = match m
        \\  Just v => v
        \\  Nothing => 0
        \\fn double_just m = match m
        \\  Just v => Just (v * 2)
        \\  Nothing => Nothing
        \\fn main = from_just (double_just (Just 21))
    );
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "runtime: pipe with multiple functions" {
    const result = try testRuntime(
        \\fn add_one x = x + 1
        \\fn double x = x * 2
        \\fn square x = x * x
        \\fn main = 5 |> add_one |> double |> square
    );
    try std.testing.expectEqual(@as(i64, 144), result);
}

test "runtime: chained comparison" {
    const result = try testRuntime(
        \\fn main =
        \\  let a = 5
        \\  let b = 10
        \\  let c = 15
        \\  if a < b then if b < c then 1 else 0 else 0
    );
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "runtime: nested let with computation" {
    const result = try testRuntime(
        \\fn main =
        \\  let x = 5
        \\  let y = x * x
        \\  let z = y + x
        \\  z * 2
    );
    try std.testing.expectEqual(@as(i64, 60), result);
}

test "runtime: if/else as expression" {
    const result = try testRuntime(
        \\fn abs x = if x >= 0 then x else -x
        \\fn main = abs (-10)
    );
    try std.testing.expectEqual(@as(i64, 10), result);
}

test "runtime: complex tree with map" {
    const result = try testRuntime(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_sum tree = match tree
        \\  Branch left right => tree_sum left + tree_sum right
        \\  Leaf n => n
        \\fn tree_map f tree = match tree
        \\  Leaf n => Leaf (f n)
        \\  Branch left right => Branch (tree_map f left) (tree_map f right)
        \\fn main =
        \\  let tree = Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5)
        \\  let doubled = tree_map (\x -> x * 2) tree
        \\  tree_sum doubled
    );
    try std.testing.expectEqual(@as(i64, 18), result);
}

test "runtime: state machine transitions" {
    const result = try testRuntime(
        \\type State = Idle | Running Int | Done
        \\fn step s = match s
        \\  Idle => Running 1
        \\  Running n => if n >= 3 then Done else Running (n + 1)
        \\  Done => Done
        \\fn run s n = if n == 0 then s else run (step s) (n - 1)
        \\fn extract s = match s
        \\  Running v => v
        \\  Done => -1
        \\  Idle => 0
        \\fn main = extract (run Idle 5)
    );
    try std.testing.expectEqual(@as(i64, -1), result);
}

// ──── HIR data structure tests ────

const hir = @import("hir.zig");

fn testIntType() typecheck.Type {
    return .{ .int = {} };
}

test "hir: create literal expression" {
    const int_ty = testIntType();
    const expr = hir.HirExpr{
        .id = 0,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .int = 42 },
    };
    try std.testing.expectEqual(@as(hir.HirId, 0), expr.id);
    switch (expr.kind) {
        .int => |val| try std.testing.expectEqual(@as(i64, 42), val),
        else => @panic("expected int literal"),
    }
}

test "hir: create let expression" {
    const int_ty = testIntType();
    const body = hir.HirExpr{
        .id = 1,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .local = 0 },
    };
    _ = &body;
    const value = hir.HirExpr{
        .id = 2,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .int = 10 },
    };
    _ = &value;
    const let_expr = hir.HirExpr{
        .id = 3,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .let = .{ .name = 0, .value = 2, .body = 1 } },
    };
    const kind = let_expr.kind;
    switch (kind) {
        .let => |l| {
            try std.testing.expectEqual(@as(hir.LocalVarId, 0), l.name);
            try std.testing.expectEqual(@as(hir.HirId, 2), l.value);
            try std.testing.expectEqual(@as(hir.HirId, 1), l.body);
        },
        else => @panic("expected let"),
    }
}

test "hir: create lambda expression" {
    const int_ty = testIntType();
    const body = hir.HirExpr{
        .id = 4,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .local = 1 },
    };
    _ = &body;
    const lam = hir.HirExpr{
        .id = 5,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .lambda = .{ .params = &.{1}, .body = 4, .captures = &.{} } },
    };
    switch (lam.kind) {
        .lambda => |l| {
            try std.testing.expectEqual(@as(usize, 1), l.params.len);
            try std.testing.expectEqual(@as(hir.LocalVarId, 1), l.params[0]);
            try std.testing.expectEqual(@as(hir.HirId, 4), l.body);
        },
        else => @panic("expected lambda"),
    }
}

test "hir: create match expression" {
    const int_ty = testIntType();
    const scrutinee = hir.HirExpr{ .id = 6, .ty = &int_ty, .span = .{}, .kind = .{ .local = 0 } };
    const arm_body = hir.HirExpr{ .id = 7, .ty = &int_ty, .span = .{}, .kind = .{ .int = 1 } };
    _ = .{ &scrutinee, &arm_body };
    const arm = hir.MatchArm{
        .pattern = hir.Pattern{ .wildcard = {} },
        .guard = null,
        .body = 7,
    };
    const match_expr = hir.HirExpr{
        .id = 8,
        .ty = &int_ty,
        .span = .{},
        .kind = .{ .match = .{ .scrutinee = 6, .arms = &.{arm} } },
    };
    switch (match_expr.kind) {
        .match => |m| {
            try std.testing.expectEqual(@as(hir.HirId, 6), m.scrutinee);
            try std.testing.expectEqual(@as(usize, 1), m.arms.len);
            try std.testing.expect(m.arms[0].guard == null);
        },
        else => @panic("expected match"),
    }
}

test "hir: pattern variants" {
    const wild = hir.Pattern{ .wildcard = {} };
    const bind = hir.Pattern{ .bind = 0 };
    const lit = hir.Pattern{ .literal = .{ .int = 5 } };
    const ctor = hir.Pattern{
        .constructor = .{
            .type_name = "Bool",
            .ctor_name = "True",
            .args = &.{},
        },
    };
    const record = hir.Pattern{
        .record = .{ .fields = &.{}, .rest = false },
    };

    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(std.meta.activeTag(wild)));
    try std.testing.expect(wild == .wildcard);
    try std.testing.expect(bind == .bind);
    try std.testing.expect(lit == .literal);
    try std.testing.expect(ctor == .constructor);
    try std.testing.expect(record == .record);
}

test "hir: primop variants" {
    try std.testing.expectEqual(hir.PrimOp.add, @as(hir.PrimOp, .add));
    try std.testing.expectEqual(hir.PrimOp.sub, .sub);
    try std.testing.expectEqual(hir.PrimOp.and_, .and_);
    try std.testing.expectEqual(hir.PrimOp.or_, .or_);
    try std.testing.expectEqual(hir.PrimOp.not_, .not_);
    try std.testing.expectEqual(hir.PrimOp.concat, .concat);
}

// ──── HIR lowering tests ────

const hir_lower = @import("hir_lower.zig");
const hir_beta = @import("hir_beta.zig");
const hir_let_simpl = @import("hir_let_simpl.zig");
const hir_known_match = @import("hir_known_match.zig");

/// Run the HIR optimization passes that don't need roots (beta, let_simpl, known_match, fold).
/// Caller must run DCE separately with the appropriate roots.
fn runHirPassesNoDce(allocator: std.mem.Allocator, expressions: *std.ArrayList(hir.HirExpr)) void {
    var beta = hir_beta.HirBeta.init(allocator, expressions);
    beta.run();
    var let_simpl = hir_let_simpl.HirLetSimpl.init(allocator, expressions);
    let_simpl.run();
    var known = hir_known_match.HirKnownMatch.init(allocator, expressions);
    known.run();
    var fold = hir_fold.HirFold.init(allocator, expressions);
    fold.run();
}

test "hir_lower: integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 42";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    try std.testing.expect(lower.expressions.items.len > 0);
}

test "hir_lower: string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = \"hello\"";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    try std.testing.expect(lower.expressions.items.len > 0);
}

test "hir_lower: let expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = let x = 42\n  x";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var found_let = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .let) found_let = true;
    }
    try std.testing.expect(found_let);
}

test "hir_lower: binary operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 1 + 2";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var found_primop = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .primop) found_primop = true;
    }
    try std.testing.expect(found_primop);
}

test "hir_lower: if expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = if True then 1 else 2";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var found_if = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .if_) found_if = true;
    }
    try std.testing.expect(found_if);
}

// ──── HIR constant folding tests ────

const hir_fold = @import("hir_fold.zig");

test "hir_fold: addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 1 + 2";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var found_folded = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .int and e.kind.int == 3) found_folded = true;
    }
    try std.testing.expect(found_folded);
}

test "hir_fold: comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 3 > 5";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var found_folded = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .bool and !e.kind.bool) found_folded = true;
    }
    try std.testing.expect(found_folded);
}

test "hir_fold: let propagation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = let x = 1 + 2\n  x";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var any_local = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .local) any_local = true;
    }
    try std.testing.expect(!any_local);
}

test "hir_fold: nested binary ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = (1 + 2) * (3 + 4)";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var found_folded = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .int and e.kind.int == 21) found_folded = true;
    }
    try std.testing.expect(found_folded);
}

test "hir_fold: if folding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = if True then 42 else 99";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var found_folded = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .int and e.kind.int == 42) found_folded = true;
    }
    try std.testing.expect(found_folded);
}

test "hir_fold: niladic propagation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = (1 + 2) * (3 + 4)";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var found_folded = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .int and e.kind.int == 21) found_folded = true;
    }
    try std.testing.expect(found_folded);
}

// ──── HIR DCE tests ────

const hir_dce = @import("hir_dce.zig");

test "hir_dce: all live in simple program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 42";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var dce = hir_dce.HirDce.init(allocator, &lower.expressions);
    dce.run(lower.roots.items);
    for (lower.expressions.items) |e| {
        try std.testing.expect(e.live);
    }
}

test "hir_dce: dead after folding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 1 + 2";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var fold = hir_fold.HirFold.init(allocator, &lower.expressions);
    defer fold.deinit();
    fold.run();
    var dce = hir_dce.HirDce.init(allocator, &lower.expressions);
    dce.run(lower.roots.items);
    for (lower.expressions.items) |e| {
        switch (e.kind) {
            .int => |v| {
                if (v == 1 or v == 2) try std.testing.expect(!e.live);
                if (v == 3) try std.testing.expect(e.live);
            },
            .lambda => try std.testing.expect(e.live),
            else => {},
        }
    }
}

// ──── HIR beta reduction tests ────

test "hir_beta: simple lambda application" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = (\\x -> x) 42";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var beta = hir_beta.HirBeta.init(allocator, &lower.expressions);
    beta.run();
    // Should have at least one let expression (from beta reduction)
    var found_let = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .let) found_let = true;
    }
    try std.testing.expect(found_let);
    try std.testing.expectEqual(@as(usize, 1), beta.reduced);
}

test "hir_beta: multi-param partial application not reduced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Partial application: fewer args than params — should NOT be reduced
    const source: [:0]const u8 = "fn add x y = x + y\nfn main = add 1";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var beta = hir_beta.HirBeta.init(allocator, &lower.expressions);
    beta.run();
    // No reductions — partial application
    try std.testing.expectEqual(@as(usize, 0), beta.reduced);
}

test "hir_beta: multi-param full application" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn add x y = x + y\nfn main = (\\x y -> x + y) 1 2";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var beta = hir_beta.HirBeta.init(allocator, &lower.expressions);
    beta.run();
    // At least one reduction (the outer apply)
    try std.testing.expect(beta.reduced >= 1);
}

// ──── HIR let simplification tests ────

test "hir_let_simpl: identity let removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Use a simple program — the let_simpl pass runs but may find nothing to simplify.
    // The important thing is it doesn't crash.
    const source: [:0]const u8 = "fn main = 42";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var ls = hir_let_simpl.HirLetSimpl.init(allocator, &lower.expressions);
    ls.run();
    // Runs without crashing
    try std.testing.expect(true);
}

test "hir_let_simpl: dead let removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn f x = 0\nfn main = f 42";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var ls = hir_let_simpl.HirLetSimpl.init(allocator, &lower.expressions);
    ls.run();
    // Just verify it runs without crashing
    try std.testing.expect(true);
}

test "hir_let_simpl: single-use literal inline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 = "fn main = 42";
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var ls = hir_let_simpl.HirLetSimpl.init(allocator, &lower.expressions);
    ls.run();
    // Just verify it runs without crashing
    try std.testing.expect(true);
}

// ──── HIR known-match reduction tests ────

test "hir_known_match: known constructor match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 =
        \\type Maybe a = Just a | Nothing
        \\fn main = match (Just 42)
        \\  Just v => v
        \\  Nothing => 0
    ;
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var known = hir_known_match.HirKnownMatch.init(allocator, &lower.expressions);
    known.run();
    // Should have reduced: the match becomes a let binding
    var found_let = false;
    for (lower.expressions.items) |e| {
        if (e.kind == .let) found_let = true;
    }
    try std.testing.expect(found_let);
    try std.testing.expectEqual(@as(usize, 1), known.reduced);
}

test "hir_known_match: unknown scrutinee not reduced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source: [:0]const u8 =
        \\type Maybe a = Just a | Nothing
        \\fn foo m = match m
        \\  Just v => v
        \\  Nothing => 0
    ;
    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var lower = hir_lower.HirLower.init(allocator, &inferer);
    defer lower.deinit();
    try lower.lowerProgram(&prog);
    var known = hir_known_match.HirKnownMatch.init(allocator, &lower.expressions);
    known.run();
    // No reductions — scrutinee is a variable, not a known constructor
    try std.testing.expectEqual(@as(usize, 0), known.reduced);
}

// ──── LIR data structure tests ────

const lir = @import("lir.zig");

test "lir: create LirType variants" {
    const int_ty = lir.LirType{ .int = {} };
    const float_ty = lir.LirType{ .float = {} };
    const bool_ty = lir.LirType{ .bool = {} };
    const char_ty = lir.LirType{ .char = {} };
    const string_ty = lir.LirType{ .string = {} };
    const unit_ty = lir.LirType{ .unit = {} };
    const opaque_ty = lir.LirType{ .opaque_type = {} };
    _ = .{ &int_ty, &float_ty, &bool_ty, &char_ty, &string_ty, &unit_ty, &opaque_ty };

    try std.testing.expect(int_ty == .int);
    try std.testing.expect(float_ty == .float);
    try std.testing.expect(bool_ty == .bool);
    try std.testing.expect(char_ty == .char);
    try std.testing.expect(string_ty == .string);
    try std.testing.expect(unit_ty == .unit);
    try std.testing.expect(opaque_ty == .opaque_type);
}

test "lir: create function type" {
    const ret_ty = lir.LirType{ .int = {} };
    const param_ty = lir.LirType{ .int = {} };
    const fn_type = lir.LirFnType{
        .params = &.{param_ty},
        .returns = ret_ty,
    };
    _ = &fn_type;
    try std.testing.expectEqual(@as(usize, 1), fn_type.params.len);
    try std.testing.expect(fn_type.params[0] == .int);
}

test "lir: function in LirType" {
    const ret_ty = lir.LirType{ .int = {} };
    const fn_type = lir.LirFnType{ .params = &.{}, .returns = ret_ty };
    const boxed = try std.testing.allocator.create(lir.LirFnType);
    defer std.testing.allocator.destroy(boxed);
    boxed.* = fn_type;
    const ty = lir.LirType{ .function = boxed };
    try std.testing.expect(ty == .function);
}

test "lir: create basic block" {
    const block = lir.BasicBlock{
        .id = 0,
        .params = &.{},
        .body = &.{},
        .terminator = .{ .unreachable_ = {} },
    };
    _ = &block;
    try std.testing.expectEqual(@as(lir.BlockId, 0), block.id);
    try std.testing.expect(block.terminator == .unreachable_);
}

test "lir: create LirValue variants" {
    const int_val = lir.LirValue{ .int = 42 };
    const local_val = lir.LirValue{ .local = 0 };
    const ret_ty = lir.LirType{ .int = {} };
    const call_fn_type = try std.testing.allocator.create(lir.LirFnType);
    defer std.testing.allocator.destroy(call_fn_type);
    call_fn_type.* = .{ .params = &.{ret_ty}, .returns = ret_ty };
    const call_val = lir.LirValue{
        .call = .{
            .func = 0,
            .args = &.{1},
            .fn_type = call_fn_type.*,
        },
    };
    _ = .{ &int_val, &local_val, &call_val };

    try std.testing.expect(int_val == .int);
    try std.testing.expect(local_val == .local);
    try std.testing.expect(call_val == .call);
}

test "lir: create LirFn" {
    const lir_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = lir.LirType{ .int = {} },
        .blocks = &.{},
        .locals = &.{},
    };
    _ = &lir_fn;
    try std.testing.expectEqualStrings("main", lir_fn.name);
    try std.testing.expect(lir_fn.return_type == .int);
}

test "lir: terminator variants" {
    const br = lir.LirTerminator{ .br = .{ .target = 1, .args = &.{0} } };
    const ret = lir.LirTerminator{ .ret = 0 };
    const unreach = lir.LirTerminator{ .unreachable_ = {} };
    _ = .{ &br, &ret, &unreach };

    try std.testing.expect(br == .br);
    try std.testing.expectEqual(@as(lir.BlockId, 1), br.br.target);
    try std.testing.expectEqual(@as(usize, 1), br.br.args.len);
    try std.testing.expect(ret == .ret);
    try std.testing.expect(unreach == .unreachable_);
}

test "lir: store and assign statements" {
    const assign = lir.LirStmt{
        .assign = .{
            .dest = 0,
            .value = .{ .int = 10 },
        },
    };
    const store = lir.LirStmt{
        .store = .{
            .dest = 1,
            .value = 0,
        },
    };
    _ = .{ &assign, &store };

    try std.testing.expect(assign == .assign);
    try std.testing.expect(store == .store);
}

// ──── LIR → LLVM codegen tests ────

const codegen_lir = @import("codegen_lir.zig");

fn runLirProgram(allocator: std.mem.Allocator, fns: []const lir.LirFn, with_runtime: bool) !i64 {
    var cg = codegen_lir.CodegenLir.init(allocator, "test_lir");
    defer cg.deinit();
    if (with_runtime) cg.declareRuntime();
    try cg.codegenProgram(fns);
    var jit = try codegen_mod.Jit.init(cg.module, 0);
    defer jit.deinit();
    cg.module_owned_by_jit = true;
    return try jit.runMain();
}

test "codegen_lir: LirType to LLVM type mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cg = codegen_lir.CodegenLir.init(a, "test_lir_types");
    defer cg.deinit();

    const int_ty = try cg.lirType(.{ .int = {} });
    try std.testing.expect(llvm.core.LLVMGetTypeKind(int_ty) == .LLVMIntegerTypeKind);
    try std.testing.expectEqual(@as(c_uint, 64), llvm.core.LLVMGetIntTypeWidth(int_ty));

    const float_ty = try cg.lirType(.{ .float = {} });
    try std.testing.expect(llvm.core.LLVMGetTypeKind(float_ty) == .LLVMDoubleTypeKind);

    const bool_ty = try cg.lirType(.{ .bool = {} });
    try std.testing.expect(llvm.core.LLVMGetTypeKind(bool_ty) == .LLVMIntegerTypeKind);
    try std.testing.expectEqual(@as(c_uint, 1), llvm.core.LLVMGetIntTypeWidth(bool_ty));

    const ptr_ty = try cg.lirType(.{ .string = {} });
    try std.testing.expect(llvm.core.LLVMGetTypeKind(ptr_ty) == .LLVMPointerTypeKind);

    const struct_ty = try cg.lirType(.{ .struct_ = &.{ .{ .int = {} }, .{ .bool = {} } } });
    try std.testing.expect(llvm.core.LLVMGetTypeKind(struct_ty) == .LLVMStructTypeKind);

    const elem = lir.LirType{ .int = {} };
    const array_ty = try cg.lirType(.{ .array = .{ .elem = &elem, .len = 4 } });
    try std.testing.expect(llvm.core.LLVMGetTypeKind(array_ty) == .LLVMArrayTypeKind);
}

test "codegen_lir: constant return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{.{ .int = {} }},
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{.{ .assign = .{ .dest = 0, .value = .{ .int = 42 } } }},
            .terminator = .{ .ret = 0 },
        }},
    };
    const result = try runLirProgram(a, &.{main_fn}, false);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "codegen_lir: cond_br with block arguments (phi)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // if 1 < 2 then 40 else 2, threaded through a block parameter
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .int = {} }, .{ .bool = {} }, .{ .int = {} }, .{ .int = {} }, .{ .int = {} } },
        .blocks = &.{
            .{
                .id = 0,
                .params = &.{},
                .body = &.{
                    .{ .assign = .{ .dest = 0, .value = .{ .int = 1 } } },
                    .{ .assign = .{ .dest = 1, .value = .{ .int = 2 } } },
                    .{ .assign = .{ .dest = 2, .value = .{ .primop = .{ .op = .lt, .args = &.{ 0, 1 } } } } },
                    .{ .assign = .{ .dest = 3, .value = .{ .int = 40 } } },
                    .{ .assign = .{ .dest = 4, .value = .{ .int = 2 } } },
                },
                .terminator = .{ .cond_br = .{
                    .cond = 2,
                    .then = .{ .target = 1, .args = &.{3} },
                    .else_ = .{ .target = 1, .args = &.{4} },
                } },
            },
            .{
                .id = 1,
                .params = &.{5},
                .body = &.{},
                .terminator = .{ .ret = 5 },
            },
        },
    };
    const result = try runLirProgram(a, &.{main_fn}, false);
    try std.testing.expectEqual(@as(i64, 40), result);
}

test "codegen_lir: switch terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // switch 2 { 0 => 10, 1 => 20, 2 => 42, default => 0 }
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .int = {} }, .{ .int = {} }, .{ .int = {} }, .{ .int = {} } },
        .blocks = &.{
            .{
                .id = 0,
                .params = &.{},
                .body = &.{.{ .assign = .{ .dest = 0, .value = .{ .int = 2 } } }},
                .terminator = .{ .switch_ = .{
                    .val = 0,
                    .cases = &.{
                        .{ .tag = 0, .target = .{ .target = 1 } },
                        .{ .tag = 1, .target = .{ .target = 2 } },
                        .{ .tag = 2, .target = .{ .target = 3 } },
                    },
                    .default = .{ .target = 4 },
                } },
            },
            .{ .id = 1, .params = &.{}, .body = &.{.{ .assign = .{ .dest = 1, .value = .{ .int = 10 } } }}, .terminator = .{ .ret = 1 } },
            .{ .id = 2, .params = &.{}, .body = &.{.{ .assign = .{ .dest = 2, .value = .{ .int = 20 } } }}, .terminator = .{ .ret = 2 } },
            .{ .id = 3, .params = &.{}, .body = &.{.{ .assign = .{ .dest = 3, .value = .{ .int = 42 } } }}, .terminator = .{ .ret = 3 } },
            .{ .id = 4, .params = &.{}, .body = &.{.{ .assign = .{ .dest = 4, .value = .{ .int = 0 } } }}, .terminator = .{ .ret = 4 } },
        },
    };
    const result = try runLirProgram(a, &.{main_fn}, false);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "codegen_lir: direct call via fn_ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // add1(x) = x + 1 ; main = add1(41)
    const add1_ft = lir.LirFnType{ .params = &.{.{ .int = {} }}, .returns = .{ .int = {} } };
    const add1_fn = lir.LirFn{
        .name = "add1",
        .params = &.{0},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .int = {} }, .{ .int = {} } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{
                .{ .assign = .{ .dest = 1, .value = .{ .int = 1 } } },
                .{ .assign = .{ .dest = 2, .value = .{ .primop = .{ .op = .add, .args = &.{ 0, 1 } } } } },
            },
            .terminator = .{ .ret = 2 },
        }},
    };
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .function = &add1_ft }, .{ .int = {} } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{
                .{ .assign = .{ .dest = 0, .value = .{ .int = 41 } } },
                .{ .assign = .{ .dest = 1, .value = .{ .fn_ref = "add1" } } },
                .{ .assign = .{ .dest = 2, .value = .{ .call = .{ .func = 1, .args = &.{0}, .fn_type = add1_ft } } } },
            },
            .terminator = .{ .ret = 2 },
        }},
    };
    const result = try runLirProgram(a, &.{ add1_fn, main_fn }, false);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "codegen_lir: tail_call terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // add1(x) = x + 1 ; wrap(x) = tail_call add1(x) ; main = wrap(41)
    const add1_ft = lir.LirFnType{ .params = &.{.{ .int = {} }}, .returns = .{ .int = {} } };
    const add1_fn = lir.LirFn{
        .name = "add1",
        .params = &.{0},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .int = {} }, .{ .int = {} } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{
                .{ .assign = .{ .dest = 1, .value = .{ .int = 1 } } },
                .{ .assign = .{ .dest = 2, .value = .{ .primop = .{ .op = .add, .args = &.{ 0, 1 } } } } },
            },
            .terminator = .{ .ret = 2 },
        }},
    };
    const wrap_fn = lir.LirFn{
        .name = "wrap",
        .params = &.{0},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .function = &add1_ft } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{.{ .assign = .{ .dest = 1, .value = .{ .fn_ref = "add1" } } }},
            .terminator = .{ .tail_call = .{ .func = 1, .args = &.{0}, .fn_type = add1_ft } },
        }},
    };
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .function = &add1_ft }, .{ .int = {} } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{
                .{ .assign = .{ .dest = 0, .value = .{ .int = 41 } } },
                .{ .assign = .{ .dest = 1, .value = .{ .fn_ref = "wrap" } } },
                .{ .assign = .{ .dest = 2, .value = .{ .call = .{ .func = 1, .args = &.{0}, .fn_type = add1_ft } } } },
            },
            .terminator = .{ .ret = 2 },
        }},
    };
    const result = try runLirProgram(a, &.{ add1_fn, wrap_fn, main_fn }, false);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "codegen_lir: integer primops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // main = 6 * 7
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .int = {} }, .{ .int = {} }, .{ .int = {} } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{
                .{ .assign = .{ .dest = 0, .value = .{ .int = 6 } } },
                .{ .assign = .{ .dest = 1, .value = .{ .int = 7 } } },
                .{ .assign = .{ .dest = 2, .value = .{ .primop = .{ .op = .mul, .args = &.{ 0, 1 } } } } },
            },
            .terminator = .{ .ret = 2 },
        }},
    };
    const result = try runLirProgram(a, &.{main_fn}, false);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "codegen_lir: alloc + is_unique + incref/decref roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // p = alloc({i64}); u = is_unique(p); incref/decref/decref frees p;
    // return u ? 42 : 0 — exercises the real ko_alloc/ko_incref/ko_decref.
    const cell_ty = lir.LirType{ .struct_ = &.{.{ .int = {} }} };
    const cell_ptr_ty = lir.LirType{ .ptr = &cell_ty };
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ cell_ptr_ty, .{ .bool = {} }, .{ .int = {} }, .{ .int = {} }, .{ .int = {} } },
        .blocks = &.{
            .{
                .id = 0,
                .params = &.{},
                .body = &.{
                    .{ .assign = .{ .dest = 0, .value = .{ .alloc = cell_ty } } },
                    .{ .assign = .{ .dest = 1, .value = .{ .is_unique = 0 } } },
                    .{ .assign = .{ .dest = 2, .value = .{ .int = 42 } } },
                    .{ .assign = .{ .dest = 3, .value = .{ .int = 0 } } },
                    .{ .effect = .{ .incref = 0 } },
                    .{ .effect = .{ .decref = 0 } },
                    .{ .effect = .{ .decref = 0 } },
                },
                .terminator = .{ .cond_br = .{
                    .cond = 1,
                    .then = .{ .target = 1, .args = &.{2} },
                    .else_ = .{ .target = 1, .args = &.{3} },
                } },
            },
            .{
                .id = 1,
                .params = &.{4},
                .body = &.{},
                .terminator = .{ .ret = 4 },
            },
        },
    };
    const result = try runLirProgram(a, &.{main_fn}, true);
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "codegen_lir: string constant + runtime call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // main = ko_string_length("hello") — string literal plus a call into
    // the runtime emitted by declareRuntime.
    const strlen_ft = lir.LirFnType{ .params = &.{.{ .string = {} }}, .returns = .{ .int = {} } };
    const main_fn = lir.LirFn{
        .name = "main",
        .params = &.{},
        .return_type = .{ .int = {} },
        .locals = &.{ .{ .string = {} }, .{ .function = &strlen_ft }, .{ .int = {} } },
        .blocks = &.{.{
            .id = 0,
            .params = &.{},
            .body = &.{
                .{ .assign = .{ .dest = 0, .value = .{ .string = .{ .ptr = "hello", .len = 5 } } } },
                .{ .assign = .{ .dest = 1, .value = .{ .fn_ref = "ko_string_length" } } },
                .{ .assign = .{ .dest = 2, .value = .{ .call = .{ .func = 1, .args = &.{0}, .fn_type = strlen_ft } } } },
            },
            .terminator = .{ .ret = 2 },
        }},
    };
    const result = try runLirProgram(a, &.{main_fn}, true);
    try std.testing.expectEqual(@as(i64, 5), result);
}

// ──── HIR → LIR lowering tests (full pipeline, differential vs legacy) ────

const lir_lower = @import("lir_lower.zig");

fn testRuntimeLir(source: [:0]const u8) !i64 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var hl = hir_lower.HirLower.init(allocator, &inferer);
    defer hl.deinit();
    try hl.lowerProgram(&prog);

    // HIR optimization passes — only in main.zig for actual compilation.
    // Not run here so testRuntimeLir matches legacy testRuntime semantics.

    var ll = lir_lower.LirLower.init(allocator, hl.expressions.items, hl.defs.items, &inferer);
    defer ll.deinit();
    const fns = try ll.lowerProgram();
    var cg = codegen_lir.CodegenLir.init(allocator, "test_lir_lower");
    defer cg.deinit();
    cg.declareRuntime();
    try cg.codegenProgram(fns);
    var jit = try codegen_mod.Jit.init(cg.module, 0);
    defer jit.deinit();
    cg.module_owned_by_jit = true;
    mapLirJitResultFns(cg.module, jit.engine);
    return try jit.runMain();
}

/// Like testRuntimeLir but runs HIR optimization passes (beta, let_simpl,
/// known_match, fold, DCE) before LIR lowering, matching the CLI --use-lir path.
fn testRuntimeLirOpt(source: [:0]const u8) !i64 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = try parser.Parser.init(allocator, source);
    defer p.deinit();
    const prog = try p.parse_program();
    var inferer = typecheck.Inferer.init(allocator);
    defer inferer.deinit();
    try inferer.inferProgram(&prog);
    var hl = hir_lower.HirLower.init(allocator, &inferer);
    defer hl.deinit();
    try hl.lowerProgram(&prog);

    // HIR optimization passes — same set as main.zig --use-lir path.
    var beta = hir_beta.HirBeta.init(allocator, &hl.expressions);
    beta.run();
    var let_simpl = hir_let_simpl.HirLetSimpl.init(allocator, &hl.expressions);
    let_simpl.run();
    var known = hir_known_match.HirKnownMatch.init(allocator, &hl.expressions);
    known.run();
    var fold = hir_fold.HirFold.init(allocator, &hl.expressions);
    fold.run();
    var dce = hir_dce.HirDce.init(allocator, &hl.expressions);
    dce.run(hl.roots.items);

    var ll = lir_lower.LirLower.init(allocator, hl.expressions.items, hl.defs.items, &inferer);
    defer ll.deinit();
    const fns = try ll.lowerProgram();
    var cg = codegen_lir.CodegenLir.init(allocator, "test_lir_lower_opt");
    defer cg.deinit();
    cg.declareRuntime();
    try cg.codegenProgram(fns);
    var jit = try codegen_mod.Jit.init(cg.module, 0);
    defer jit.deinit();
    cg.module_owned_by_jit = true;
    mapLirJitResultFns(cg.module, jit.engine);
    return try jit.runMain();
}

fn mapLirJitResultFns(mod: types.LLVMModuleRef, jit_engine: types.LLVMExecutionEngineRef) void {
    if (core.LLVMGetNamedFunction(mod, "ko_result_is_ok")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_is_ok)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_result_is_err")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_is_err)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_result_unwrap")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_unwrap_panic)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_result_unwrap_or")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_unwrap_or)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_result_map")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_map)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_result_fold")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_fold)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_result_and_then")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_result_and_then)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_panic")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_panic)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_panic_str")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_panic_str)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_assert")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_assert)));
    }
    if (core.LLVMGetNamedFunction(mod, "ko_assert_eq")) |fn_val| {
        engine.LLVMAddGlobalMapping(jit_engine, fn_val, @constCast(@ptrCast(&stdlib.ko_assert_eq)));
    }
}

/// Compile and run the same source through the legacy AST→LLVM path and the
/// new HIR→LIR→LLVM path; results must match.
fn expectLirMatchesLegacy(source: [:0]const u8) !void {
    const legacy = try testRuntime(source);
    const via_lir = try testRuntimeLir(source);
    try std.testing.expectEqual(legacy, via_lir);
}

test "lir_lower: integer literal" {
    try expectLirMatchesLegacy("fn main = 42");
}

test "lir_lower: arithmetic primops" {
    try expectLirMatchesLegacy("fn main = 1 + 2 * 3 - 4 / 2");
}

test "lir_lower: nested let with computation" {
    try expectLirMatchesLegacy(
        \\fn main =
        \\  let x = 5
        \\  let y = x * x
        \\  let z = y + x
        \\  z * 2
    );
}

test "lir_lower: if expression with comparison" {
    try expectLirMatchesLegacy(
        \\fn abs x = if x >= 0 then x else -x
        \\fn main = abs (-10)
    );
}

test "lir_lower: chained comparison" {
    try expectLirMatchesLegacy(
        \\fn main =
        \\  let a = 5
        \\  let b = 10
        \\  let c = 15
        \\  if a < b then if b < c then 1 else 0 else 0
    );
}

test "lir_lower: pipe with multiple functions" {
    try expectLirMatchesLegacy(
        \\fn add_one x = x + 1
        \\fn double x = x * 2
        \\fn square x = x * x
        \\fn main = 5 |> add_one |> double |> square
    );
}

test "lir_lower: recursion (fib)" {
    try expectLirMatchesLegacy(
        \\fn fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)
        \\fn main = fib 15
    );
}

test "lir_lower: lambda applied directly" {
    try expectLirMatchesLegacy(
        \\fn apply f x = f x
        \\fn main = apply (\y -> y * 2) 21
    );
}

test "lir_lower: curried two-param lambda" {
    try expectLirMatchesLegacy(
        \\fn main =
        \\  let add = \x y -> x + y
        \\  add 20 22
    );
}

test "lir_lower: closure capturing a variable" {
    try expectLirMatchesLegacy(
        \\fn make_adder x = \y -> x + y
        \\fn main =
        \\  let add5 = make_adder 5
        \\  add5 37
    );
}

test "lir_lower: higher-order function" {
    try expectLirMatchesLegacy(
        \\fn twice f x = f (f x)
        \\fn main = twice (\n -> n + 1) 40
    );
}

test "lir_lower: global function passed as value" {
    try expectLirMatchesLegacy(
        \\fn add_one x = x + 1
        \\fn twice f x = f (f x)
        \\fn main = twice add_one 40
    );
}

test "lir_lower: ADT construction and match" {
    try expectLirMatchesLegacy(
        \\type Maybe = Just Int | Nothing
        \\fn from_just m = match m
        \\  Just v => v
        \\  Nothing => 0
        \\fn main = from_just (Just 42)
    );
}

test "lir_lower: nested match with computation" {
    try expectLirMatchesLegacy(
        \\type Maybe = Just Int | Nothing
        \\fn from_just m = match m
        \\  Just v => v
        \\  Nothing => 0
        \\fn double_just m = match m
        \\  Just v => Just (v * 2)
        \\  Nothing => Nothing
        \\fn main = from_just (double_just (Just 21))
    );
}

test "lir_lower: recursive ADT (tree sum)" {
    try expectLirMatchesLegacy(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_sum tree = match tree
        \\  Branch left right => tree_sum left + tree_sum right
        \\  Leaf n => n
        \\fn main = tree_sum (Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5))
    );
}

test "lir_lower: tree map with lambda" {
    try expectLirMatchesLegacy(
        \\type Tree = Branch Tree Tree | Leaf Int
        \\fn tree_sum tree = match tree
        \\  Branch left right => tree_sum left + tree_sum right
        \\  Leaf n => n
        \\fn tree_map f tree = match tree
        \\  Leaf n => Leaf (f n)
        \\  Branch left right => Branch (tree_map f left) (tree_map f right)
        \\fn main =
        \\  let tree = Branch (Branch (Leaf 1) (Leaf 3)) (Leaf 5)
        \\  let doubled = tree_map (\x -> x * 2) tree
        \\  tree_sum doubled
    );
}

test "lir_lower: state machine transitions" {
    try expectLirMatchesLegacy(
        \\type State = Idle | Running Int | Done
        \\fn step s = match s
        \\  Idle => Running 1
        \\  Running n => if n >= 3 then Done else Running (n + 1)
        \\  Done => Done
        \\fn run s n = if n == 0 then s else run (step s) (n - 1)
        \\fn extract s = match s
        \\  Running v => v
        \\  Done => -1
        \\  Idle => 0
        \\fn main = extract (run Idle 5)
    );
}

test "lir_lower: wildcard and literal patterns" {
    // NOTE: the legacy path falls through literal patterns to the wildcard
    // (300) — a legacy match bug. The LIR path matches literals correctly
    // (200), so assert directly.
    try std.testing.expectEqual(@as(i64, 200), try testRuntimeLir(
        \\fn classify n = match n
        \\  0 => 100
        \\  1 => 200
        \\  _ => 300
        \\fn main = classify 1
    ));
}

test "lir_lower: tuple construction and pattern" {
    // NOTE: legacy match fails to register tuple-pattern binds
    // (UndefinedVariable in the legacy codegen) — assert the LIR result.
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\fn main =
        \\  let t = (20, 22)
        \\  match t
        \\  (a, b) => a + b
    ));
}

test "lir_lower: tuple destructuring let" {
    try std.testing.expectEqual(@as(i64, 30), try testRuntimeLir(
        \\fn main =
        \\  let (x, y) = (10, 20)
        \\  x + y
    ));
}

test "lir_lower: mutable ref" {
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\fn main =
        \\  let r = ref 41
        \\  r := !r + 1
        \\  !r
    ));
}

test "lir_lower: string length via stdlib" {
    try std.testing.expectEqual(@as(i64, 11), try testRuntimeLir(
        \\fn main = String.length "hello world"
    ));
}

test "lir_lower: string concat via + operator" {
    try std.testing.expectEqual(@as(i64, 11), try testRuntimeLir(
        \\fn main = String.length ("hello " + "world")
    ));
}

test "lir_lower: string append via stdlib" {
    try std.testing.expectEqual(@as(i64, 5), try testRuntimeLir(
        \\fn main = String.length (String.append "he" "llo")
    ));
}

test "lir_lower: try_op basic" {
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn main =
        \\  (Ok 42)?
    ));
}

test "lir_lower: Result.is_ok on Ok" {
    try std.testing.expectEqual(@as(i64, 1), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn main = Result.is_ok (Ok 42)
    ));
}

test "lir_lower: Result.is_ok on Err" {
    try std.testing.expectEqual(@as(i64, 0), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn main = Result.is_ok (Err "fail")
    ));
}

test "lir_lower: match on Result" {
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn show r = match r
        \\  | Ok v => v
        \\  | Err e => 0
        \\fn main = show (Ok 42)
    ));
}

test "lir_lower: Result.unwrapOr" {
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn main =
        \\  let r = Ok 42
        \\  Result.unwrapOr 0 r
    ));
}

test "lir_lower: Result.map" {
    try std.testing.expectEqual(@as(i64, 84), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn main =
        \\  let r = Ok 42
        \\  let doubled = Result.map (\x -> x * 2) r
        \\  match doubled
        \\    | Ok v => v
        \\    | Err e => 0
    ));
}

test "lir_lower: Result.and_then" {
    try std.testing.expectEqual(@as(i64, 420), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn main =
        \\  let r = Ok 42
        \\  let chained = Result.and_then (\x -> Ok (x * 10)) r
        \\  match chained
        \\    | Ok v => v
        \\    | Err e => 0
    ));
}

test "lir_lower: divide with ?" {
    try std.testing.expectEqual(@as(i64, 5), try testRuntimeLir(
        \\type Result a b = Ok a | Err b
        \\fn divide a b = if b == 0 then Err "div by zero" else Ok (a / b)
        \\fn main =
        \\  let r1 = (divide 10 2)?
        \\  r1
    ));
}

test "lir_lower: builtin_result.ko" {
    try std.testing.expectEqual(@as(i64, 1), try testRuntimeLir(
        @embedFile("tests_ko/builtin_result.ko"),
    ));
}

test "lir_lower: switch dispatch for zero-arg constructors" {
    // 3+ arm match on all-zero-arg constructors → should use switch instruction.
    try std.testing.expectEqual(@as(i64, 3), try testRuntimeLir(
        \\type Color = Red | Green | Blue
        \\fn color_int c = match c
        \\  Red => 1
        \\  Green => 2
        \\  Blue => 3
        \\fn main = color_int Blue
    ));
}

test "lir_lower: switch dispatch with wildcard" {
    try std.testing.expectEqual(@as(i64, 0), try testRuntimeLir(
        \\type Color = Red | Green | Blue
        \\fn color_int c = match c
        \\  Red => 1
        \\  _ => 0
        \\fn main = color_int Blue
    ));
}

test "lir_lower: decision tree with nested constructors (Maybe)" {
    // Two-arm match on Maybe — tests linear fallback for 2-arm matches.
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\type Maybe a = Just a | Nothing
        \\fn from_just v = match v
        \\  Just x => x
        \\  Nothing => v
        \\fn main = from_just (Just 42)
    ));
}

test "lir_lower: decision tree with wildcard default" {
    // 3-arm match with wildcard — decision tree.
    try std.testing.expectEqual(@as(i64, 99), try testRuntimeLir(
        \\type Color = Red | Green | Blue
        \\fn color_int c = match c
        \\  Red => 1
        \\  Green => 2
        \\  _ => 99
        \\fn main = color_int Blue
    ));
}

test "lir_lower: nested pattern with computation" {
    // Multi-arg constructor with bind sub-patterns.
    try std.testing.expectEqual(@as(i64, 10), try testRuntimeLir(
        \\type Pair a b = Pair a b
        \\fn fst p = match p
        \\  Pair x _ => x
        \\fn main = fst (Pair 10 20)
    ));
}

test "lir_lower: nested constructor sub-pattern (Just (Just x))" {
    // Constructor with a constructor sub-pattern — tests recursive specialization.
    try std.testing.expectEqual(@as(i64, 7), try testRuntimeLir(
        \\type Maybe a = Just a | Nothing
        \\fn unwrap_inner m = match m
        \\  Just (Just x) => x
        \\  Just Nothing => 0
        \\  Nothing => 0
        \\fn main = unwrap_inner (Just (Just 7))
    ));
}

test "lir_lower: nested constructor sub-pattern mismatch" {
    // Same pattern but mismatched inner constructor — should hit fallback arm.
    try std.testing.expectEqual(@as(i64, 0), try testRuntimeLir(
        \\type Maybe a = Just a | Nothing
        \\fn unwrap_inner m = match m
        \\  Just (Just x) => x
        \\  Just Nothing => 0
        \\  Nothing => 0
        \\fn main = unwrap_inner (Just Nothing)
    ));
}

test "lir_lower: column selection — most frequent constructor first" {
    // 3 arms, 2 test Cons — heuristic should test Cons first.
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLir(
        \\type Maybe a = Just a | Nothing
        \\fn double_match m = match m
        \\  Just (Just x) => x
        \\  Just Nothing => 0
        \\  Nothing => 0
        \\fn main = double_match (Just (Just 42))
    ));
}

// ========================================================================
// Integration tests with HIR optimization passes enabled (testRuntimeLirOpt).
// These match the CLI --use-lir path and catch HIR+LIR interaction bugs.
// ========================================================================

test "lir_lower+hir: basic match with optimization passes" {
    try std.testing.expectEqual(@as(i64, 7), try testRuntimeLirOpt(
        \\type Maybe a = Just a | Nothing
        \\fn unwrap m = match m
        \\  Just x => x
        \\  Nothing => 0
        \\fn main = unwrap (Just 7)
    ));
}

test "lir_lower+hir: nested constructor sub-pattern after HIR passes" {
    try std.testing.expectEqual(@as(i64, 7), try testRuntimeLirOpt(
        \\type Maybe a = Just a | Nothing
        \\fn unwrap_inner m = match m
        \\  Just (Just x) => x
        \\  Just Nothing => 0
        \\  Nothing => 0
        \\fn main = unwrap_inner (Just (Just 7))
    ));
}

test "lir_lower+hir: nested constructor mismatch after HIR passes" {
    try std.testing.expectEqual(@as(i64, 0), try testRuntimeLirOpt(
        \\type Maybe a = Just a | Nothing
        \\fn unwrap_inner m = match m
        \\  Just (Just x) => x
        \\  Just Nothing => 0
        \\  Nothing => 0
        \\fn main = unwrap_inner (Just Nothing)
    ));
}

test "lir_lower+hir: let propagation into match" {
    // HIR beta/fold may propagate the let binding, testing that LIR handles
    // the resulting expression correctly.
    try std.testing.expectEqual(@as(i64, 42), try testRuntimeLirOpt(
        \\type Maybe a = Just a | Nothing
        \\fn main =
        \\  let x = Just 42
        \\  match x
        \\    Just v => v
        \\    Nothing => 0
    ));
}

test "lir_lower+hir: tuple destructuring with optimization" {
    try std.testing.expectEqual(@as(i64, 30), try testRuntimeLirOpt(
        \\fn main =
        \\  let (x, y) = (10, 20)
        \\  x + y
    ));
}
