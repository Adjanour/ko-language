const std = @import("std");
const Io = std.Io;
const compat = @import("compat.zig");
const posix = std.posix;
const fdio = @import("fdio.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const typecheck_mod = @import("typecheck.zig");
const module_loader_mod = @import("module_loader.zig");
const diagnostics_mod = @import("diagnostics.zig");

/// Import load failures are reported as pinpointed LSP diagnostics by the
/// analyzer below; the checker's stderr logging for them is silenced via
/// `Inferer.quiet_import_errors` (std.log has no level below `err`).

const JsonValue = std.json.Value;

// Document Store
//
// Each open document owns an arena: every analysis allocation (text,
// parse tree, type environment, error strings) comes from it, so
// re-analyzing or closing a document frees everything with one
// `arena.deinit()`. Only the map key (uri) lives on the store allocator.
//
const Document = struct {
    uri: []const u8,
    /// Heap-stable arena: every analysis allocation comes from it, so
    /// re-analyzing or closing frees everything with one deinit. It must
    /// be heap-allocated (not inline) because hashmap growth memcpys
    /// Documents — any Allocator captured from an inline arena would
    /// dangle after a move. The pointer itself never moves.
    arena: *std.heap.ArenaAllocator,
    text: []const u8,
    source_z: ?[]const u8,
    version: i32,
    prog: ?ast.Program,
    inferer: ?typecheck_mod.Inferer,
    /// Module loader for this document's imports (stdlib + siblings).
    /// Arena-owned; doubles as the cross-file definition index.
    loader: module_loader_mod.ModuleLoader,
    /// All checker diagnostics (multi-error mode); may be non-empty even
    /// when inference ultimately fails. Arena-owned.
    diag_list: diagnostics_mod.DiagnosticList,
    parse_error: ?[]const u8,
    parse_error_loc: ?ast.Loc,
    type_error: ?[]const u8,
    type_error_loc: ?ast.Loc,
    type_error_expected: ?[]const u8,
    type_error_actual: ?[]const u8,
};

const DocumentStore = struct {
    documents: std.StringHashMap(Document),
    allocator: std.mem.Allocator,
    /// Directory containing the ko-lsp binary (resolves symlinks);
    /// used to find the stdlib next to the binary. Process lifetime.
    exe_dir: ?[]const u8,
    /// Optional KO_STDLIB_PATH override. Process lifetime (environ memory).
    stdlib_override: ?[]const u8,

    fn init(allocator: std.mem.Allocator, exe_dir: ?[]const u8, stdlib_override: ?[]const u8) DocumentStore {
        return .{
            .documents = std.StringHashMap(Document).init(allocator),
            .allocator = allocator,
            .exe_dir = exe_dir,
            .stdlib_override = stdlib_override,
        };
    }

    fn deinit(self: *DocumentStore) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.freeDocument(entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.documents.deinit();
    }

    fn freeDocument(self: *DocumentStore, doc: *Document) void {
        doc.arena.deinit();
        self.allocator.destroy(doc.arena);
    }

    fn open(self: *DocumentStore, uri: []const u8, text: []const u8, version: i32) !*Document {
        if (self.documents.getEntry(uri)) |entry| {
            const stored_uri = entry.value_ptr.uri;
            self.freeDocument(entry.value_ptr);
            entry.value_ptr.* = try self.freshDocument(stored_uri, text, version);
            self.analyze(entry.value_ptr);
            return entry.value_ptr;
        }
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const result = try self.documents.getOrPut(owned_uri);
        result.value_ptr.* = try self.freshDocument(result.key_ptr.*, text, version);
        self.analyze(result.value_ptr);
        return result.value_ptr;
    }

    fn update(self: *DocumentStore, uri: []const u8, text: []const u8, version: i32) !void {
        const entry = self.documents.getEntry(uri) orelse return;
        const stored_uri = entry.value_ptr.uri;
        self.freeDocument(entry.value_ptr);
        entry.value_ptr.* = try self.freshDocument(stored_uri, text, version);
        self.analyze(entry.value_ptr);
    }

    fn freshDocument(self: *DocumentStore, stored_uri: []const u8, text: []const u8, version: i32) !Document {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const owned_text = try alloc.dupe(u8, text);
        return .{
            .uri = stored_uri,
            .arena = arena,
            .text = owned_text,
            .source_z = null,
            .version = version,
            .prog = null,
            .inferer = null,
            .loader = module_loader_mod.ModuleLoader.init(alloc, baseDirOf(uriToPath(stored_uri)), self.stdlib_override, self.exe_dir),
            .diag_list = diagnostics_mod.DiagnosticList.init(alloc),
            .parse_error = null,
            .parse_error_loc = null,
            .type_error = null,
            .type_error_loc = null,
            .type_error_expected = null,
            .type_error_actual = null,
        };
    }

    fn close(self: *DocumentStore, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            var value = kv.value;
            self.freeDocument(&value);
            self.allocator.free(kv.key);
        }
    }

    fn get(self: *DocumentStore, uri: []const u8) ?*Document {
        return self.documents.getPtr(uri);
    }

    fn analyze(self: *DocumentStore, doc: *Document) void {
        _ = self;
        const alloc = doc.arena.allocator();
        const source_z = compat.dupeZ(alloc, doc.text) catch return;
        var p = parser.Parser.init(alloc, source_z) catch |err| {
            doc.parse_error = std.fmt.allocPrint(alloc, "Parse init error: {}", .{err}) catch null;
            return;
        };
        defer p.deinit();
        const prog = p.parse_program() catch |err| {
            doc.parse_error = std.fmt.allocPrint(alloc, "Parse error: {}", .{err}) catch null;
            if (p.last_error) |ec| {
                doc.parse_error_loc = ec.loc;
            }
            return;
        };
        doc.source_z = source_z;
        doc.prog = prog;
        var inferer = typecheck_mod.Inferer.init(alloc);
        // Resolve imports exactly like `ko --check`, and collect errors
        // instead of aborting: definitions that check cleanly keep their
        // schemes, so the rest of the file keeps working.
        inferer.module_loader = &doc.loader;
        inferer.diagnostics = &doc.diag_list;
        inferer.quiet_import_errors = true;
        inferer.inferProgram(&prog) catch |err| {
            if (inferer.last_error) |ec| {
                doc.type_error = ec.message;
                doc.type_error_loc = ec.loc;
                doc.type_error_expected = ec.expected;
                doc.type_error_actual = ec.actual;
            } else {
                doc.type_error = std.fmt.allocPrint(alloc, "Type error: {}", .{err}) catch null;
            }
            // No inferer.deinit(): every typechecker allocation comes from
            // the document arena, which frees everything at once.
        };
        // The inferer holds partial results (plus dummy types for failed
        // definitions); keep it so good definitions stay navigable.
        doc.inferer = inferer;
        // Pinpoint unresolvable imports at the import statement itself.
        // (The checker only reports the downstream unknown names.)
        for (prog.imports) |imp| {
            const loaded = doc.loader.loadModule(imp.path) catch continue;
            if (loaded != null) continue;
            var dotted = std.ArrayList(u8).initCapacity(alloc, 32) catch continue;
            for (imp.path, 0..) |part, i| {
                if (i > 0) dotted.append(alloc, '.') catch continue;
                dotted.appendSlice(alloc, part) catch continue;
            }
            const msg = std.fmt.allocPrint(alloc, "cannot resolve module '{s}'", .{dotted.items}) catch continue;
            doc.diag_list.addError(msg, imp.loc) catch {};
        }
    }
};

/// Strip the `file://` scheme from a document URI. Percent-escapes are
/// left as-is (paths with spaces are a known limitation).
fn uriToPath(uri: []const u8) []const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return uri;
}

/// Directory containing the file at `path`, or "" when unknown.
fn baseDirOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

//
// JSON helpers
//

fn jsonGetString(obj: JsonValue, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return if (val == .string) val.string else null;
}

fn jsonGetInt(obj: JsonValue, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return if (val == .integer) val.integer else null;
}

fn jsonGetObj(obj: JsonValue, key: []const u8) ?JsonValue {
    if (obj != .object) return null;
    return obj.object.get(key);
}

//
// LSP I/O — cross-platform via fdio (integer CRT fds on every platform)
//

fn rawRead(fd: fdio.fd_t, buf: []u8) !usize {
    const n = fdio.read(fd, buf);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

fn rawReadExact(fd: fdio.fd_t, buf: []u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try rawRead(fd, buf[pos..]);
        if (n == 0) return error.ConnectionClosed;
        pos += n;
    }
}

fn readLine(fd: fdio.fd_t, line_buf: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < line_buf.len) {
        const n = rawRead(fd, line_buf[line_len .. line_len + 1]) catch |err| {
            if (err == error.ConnectionClosed) return error.ConnectionClosed;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        if (line_buf[line_len] == '\n') break;
        line_len += n;
    }
    const end = if (line_len > 0 and line_buf[line_len - 1] == '\r') line_len - 1 else line_len;
    return line_buf[0..end];
}

fn readContentLength() !usize {
    var content_length: ?usize = null;
    var line_buf: [256]u8 = undefined;

    while (true) {
        const line = readLine(fdio.stdin, &line_buf) catch {
            if (content_length) |_| return error.MissingContentLength;
            return error.ConnectionClosed;
        };
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            content_length = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch null;
        }
    }
    return content_length orelse return error.MissingContentLength;
}

fn readExact(buf: []u8) !void {
    try rawReadExact(fdio.stdin, buf);
}

fn writeAll(fd: fdio.fd_t, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = fdio.write(fd, data[pos..]);
        if (rc < 0) {
            const e = std.c.errno(rc);
            switch (e) {
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        pos += @intCast(rc);
    }
}

fn sendResponse(id: i64, json_body: []const u8, gpa: std.mem.Allocator) !void {
    const msg = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, json_body });
    defer gpa.free(msg);
    const header = try std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n", .{msg.len});
    defer gpa.free(header);
    try writeAll(fdio.stdout, header);
    try writeAll(fdio.stdout, msg);
}

fn sendNullResult(id: i64, gpa: std.mem.Allocator) !void {
    return sendResponse(id, "null", gpa);
}

fn sendNotification(method: []const u8, params_json: []const u8, gpa: std.mem.Allocator) !void {
    const msg = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
    defer gpa.free(msg);
    const header = try std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n", .{msg.len});
    defer gpa.free(header);
    try writeAll(fdio.stdout, header);
    try writeAll(fdio.stdout, msg);
}

//
// Helpers
//

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// A 0-based [start, end) span of characters within one line.
const Span = struct { start: usize, end: usize };

fn getWordAtPosition(text: []const u8, line: usize, character: usize) ?struct { word: []const u8, start: usize, end: usize } {
    const line_text = getLine(text, line) orelse return null;
    const pos = @min(line_text.len, character);
    var start = pos;
    while (start > 0 and isIdentChar(line_text[start - 1])) start -= 1;
    var end = pos;
    while (end < line_text.len and isIdentChar(line_text[end])) end += 1;
    if (start >= end) return null;
    return .{ .word = line_text[start..end], .start = start, .end = end };
}

/// Fetch a single line (0-based) without its trailing newline.
fn getLine(text: []const u8, line: usize) ?[]const u8 {
    var current_line: usize = 0;
    var line_start: usize = 0;
    for (text, 0..) |c, i| {
        if (current_line == line) {
            var line_end = i;
            while (line_end < text.len and text[line_end] != '\n') line_end += 1;
            var s = text[line_start..line_end];
            if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
            return s;
        }
        if (c == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }
    // Last line without trailing newline.
    if (current_line == line and line_start <= text.len) {
        var s = text[line_start..];
        if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
        return s;
    }
    return null;
}

/// Locate a definition name on its (1-based) definition line: skip leading
/// whitespace, an optional `pub`, and the keyword, then match `name`.
/// Returns 0-based [start, end) character offsets, or null.
fn findDefName(line_text: []const u8, name: []const u8) ?Span {
    var i: usize = 0;
    while (i < line_text.len and (line_text[i] == ' ' or line_text[i] == '\t')) i += 1;
    if (std.mem.startsWith(u8, line_text[i..], "pub")) {
        const after = i + 3;
        if (after < line_text.len and (line_text[after] == ' ' or line_text[after] == '\t')) {
            i = after;
            while (i < line_text.len and (line_text[i] == ' ' or line_text[i] == '\t')) i += 1;
        }
    }
    // Skip the keyword itself.
    while (i < line_text.len and isIdentChar(line_text[i])) i += 1;
    while (i < line_text.len and (line_text[i] == ' ' or line_text[i] == '\t')) i += 1;
    if (i + name.len <= line_text.len and std.mem.eql(u8, line_text[i .. i + name.len], name)) {
        const after = i + name.len;
        if (after >= line_text.len or !isIdentChar(line_text[after])) {
            return .{ .start = i, .end = after };
        }
    }
    // Fallback: first whole-word occurrence anywhere on the line.
    return findWordOnLine(line_text, name);
}

/// First whole-word occurrence of `word` on one line (0-based offsets).
fn findWordOnLine(line_text: []const u8, word: []const u8) ?Span {
    if (word.len == 0 or word.len > line_text.len) return null;
    var i: usize = 0;
    while (i + word.len <= line_text.len) : (i += 1) {
        if (std.mem.eql(u8, line_text[i .. i + word.len], word)) {
            const before_ok = i == 0 or !isIdentChar(line_text[i - 1]);
            const after = i + word.len;
            const after_ok = after >= line_text.len or !isIdentChar(line_text[after]);
            if (before_ok and after_ok) return .{ .start = i, .end = after };
        }
    }
    return null;
}

/// If `pos` (0-based offset into `line_text`) sits just after a `.`,
/// return the module qualifier preceding it (e.g. `Int` in `Int.toString`).
fn getQualifier(line_text: []const u8, word_start: usize) ?[]const u8 {
    if (word_start == 0 or line_text[word_start - 1] != '.') return null;
    const end = word_start - 1;
    var start = end;
    while (start > 0 and isIdentChar(line_text[start - 1])) start -= 1;
    if (start >= end) return null;
    return line_text[start..end];
}

//
// Constants
//

const initialize_result =
    \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"hoverProvider":true,"completionProvider":{"triggerCharacters":[".",":"]},"definitionProvider":true,"documentSymbolProvider":true,"referencesProvider":true}}
;

const KEYWORD_DOCS = [_][2][]const u8{
    .{ "fn", "Define a function: `fn add x y = x + y`. Call with spaces, no parens: `add 1 2`." },
    .{ "let", "Immutable binding: `let x = 42`. The value must stay on the same line as `=`." },
    .{ "type", "Algebraic data type or record: `type Maybe a = Just a | Nothing`." },
    .{ "import", "Import a module: `import std.List`, selective `import std.List.{map}`, aliased `import std.Int as I`. Bare names import local `.ko` files." },
    .{ "match", "Pattern match: arms use `| Pattern => expr`. No nested patterns — nest `match` instead." },
    .{ "if", "If expression, returns a value: `if x > 0 then x else -x`. `else` may be omitted." },
    .{ "then", "Separates the condition from the value in `if` expressions." },
    .{ "else", "Fallback branch of `if`. Chains: `else if ... else ...`." },
    .{ "ref", "Mutable reference cell: `let c = ref 0`, read with `!c`, write with `c := v`." },
    .{ "comptime", "Compile-time evaluation: `let x = comptime (2 + 3)`." },
    .{ "pub", "Export a definition from its module." },
    .{ "module", "Declare a module block: `module Name` followed by an indented block." },
    .{ "as", "Alias an import: `import std.Int as I`." },
    .{ "and", "Boolean conjunction (also `&&`)." },
    .{ "or", "Boolean disjunction (also `||`)." },
    .{ "not", "Boolean negation (also `!`)." },
    .{ "in", "Reserved keyword." },
};

const BUILTIN_DOCS = [_][2][]const u8{
    .{ "println", "`println x` — print with trailing newline (strings print unquoted)." },
    .{ "print", "`print x` — print without trailing newline." },
    .{ "inspect", "`inspect x` — print the debug representation (strings quoted)." },
    .{ "Int.toString", "`Int.toString n: Int -> String`." },
    .{ "Int.abs", "`Int.abs n: Int -> Int`." },
    .{ "Int.min", "`Int.min a b: Int -> Int -> Int`." },
    .{ "Int.max", "`Int.max a b: Int -> Int -> Int`." },
    .{ "Int.pow", "`Int.pow base exp: Int -> Int -> Int`." },
    .{ "Int.gcd", "`Int.gcd a b: Int -> Int -> Int`." },
    .{ "Int.lcm", "`Int.lcm a b: Int -> Int -> Int`." },
    .{ "Int.factorial", "`Int.factorial n: Int -> Int`." },
    .{ "Int.isqrt", "`Int.isqrt n: Int -> Int` — integer square root." },
    .{ "Float.ofInt", "`Float.ofInt n: Int -> Float`." },
    .{ "Float.toInt", "`Float.toInt f: Float -> Int` (truncates)." },
    .{ "Float.sqrt", "`Float.sqrt f: Float -> Float`." },
    .{ "Float.pow", "`Float.pow b e: Float -> Float -> Float`." },
    .{ "Float.sin", "`Float.sin f: Float -> Float`. Also `cos`, `tan`." },
    .{ "Float.cos", "`Float.cos f: Float -> Float`." },
    .{ "Float.tan", "`Float.tan f: Float -> Float`." },
    .{ "Float.log", "`Float.log f: Float -> Float` — natural log. Also `log2`, `log10`." },
    .{ "Float.exp", "`Float.exp f: Float -> Float`." },
    .{ "Float.floor", "`Float.floor f: Float -> Float`. Also `ceil`." },
    .{ "Float.ceil", "`Float.ceil f: Float -> Float`." },
    .{ "Float.abs", "`Float.abs f: Float -> Float`." },
    .{ "String.length", "`String.length s: String -> Int`." },
    .{ "String.append", "`String.append a b: String -> String -> String`." },
    .{ "True", "Boolean constructor." },
    .{ "False", "Boolean constructor." },
};

//
// Handlers
//

fn sendHoverMarkdown(id: i64, gpa: std.mem.Allocator, markdown: []const u8) !void {
    const escaped = try escapeJsonString(gpa, markdown);
    defer gpa.free(escaped);
    var body = try std.ArrayList(u8).initCapacity(gpa, escaped.len + 64);
    defer body.deinit(gpa);
    try body.print(gpa, "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}", .{escaped});
    return sendResponse(id, try body.toOwnedSlice(gpa), gpa);
}

fn handleHover(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return sendNullResult(id, gpa);
    const uri = jsonGetString(td, "uri") orelse return sendNullResult(id, gpa);
    const pos = jsonGetObj(params, "position") orelse return sendNullResult(id, gpa);
    const line: usize = @intCast(jsonGetInt(pos, "line") orelse 0);
    const char: usize = @intCast(jsonGetInt(pos, "character") orelse 0);
    const doc = store.get(uri) orelse return sendNullResult(id, gpa);
    const wi = getWordAtPosition(doc.text, line, char) orelse return sendNullResult(id, gpa);

    const builtins_info = [_][2][]const u8{
        .{ "Int", "Integer type (64-bit)" },
        .{ "Float", "Floating-point type (64-bit)" },
        .{ "Bool", "Boolean type (true | false)" },
        .{ "String", "String type (UTF-8)" },
        .{ "Char", "Character type" },
        .{ "Unit", "Unit type (empty tuple)" },
    };
    for (builtins_info) |b| {
        if (std.mem.eql(u8, wi.word, b[0])) {
            var md_buf: [256]u8 = undefined;
            const md = try std.fmt.bufPrint(&md_buf, "**{s}**: {s}", .{ b[0], b[1] });
            return sendHoverMarkdown(id, gpa, md);
        }
    }

    // Qualified lookup first: `Int.toString` when hovering `toString`.
    if (getLine(doc.text, line)) |line_text| {
        if (getQualifier(line_text, wi.start)) |qual| {
            var qbuf: [128]u8 = undefined;
            if (qual.len + 1 + wi.word.len <= qbuf.len) {
                @memcpy(qbuf[0..qual.len], qual);
                qbuf[qual.len] = '.';
                @memcpy(qbuf[qual.len + 1 ..][0..wi.word.len], wi.word);
                const qualified = qbuf[0 .. qual.len + 1 + wi.word.len];
                for (BUILTIN_DOCS) |b| {
                    if (std.mem.eql(u8, qualified, b[0])) {
                        return sendHoverMarkdown(id, gpa, b[1]);
                    }
                }
            }
        }
    }

    for (BUILTIN_DOCS) |b| {
        if (std.mem.eql(u8, wi.word, b[0])) {
            return sendHoverMarkdown(id, gpa, b[1]);
        }
    }

    for (KEYWORD_DOCS) |k| {
        if (std.mem.eql(u8, wi.word, k[0])) {
            var md_buf: [512]u8 = undefined;
            const md = try std.fmt.bufPrint(&md_buf, "**{s}** (keyword)\n\n{s}", .{ k[0], k[1] });
            return sendHoverMarkdown(id, gpa, md);
        }
    }

    if (doc.inferer) |*inferer| {
        if (inferer.global.getScheme(wi.word)) |scheme| {
            const type_str = typecheck_mod.typeToString(gpa, scheme.body.*) catch "unknown";
            defer if (!std.mem.eql(u8, type_str, "unknown")) gpa.free(type_str);

            var md = try std.ArrayList(u8).initCapacity(gpa, 256);
            defer md.deinit(gpa);

            if (inferer.doc_comments.get(wi.word)) |docs| {
                for (docs) |doc_line| {
                    try md.appendSlice(gpa, doc_line);
                    try md.append(gpa, '\n');
                }
                try md.append(gpa, '\n');
            }

            try md.print(gpa, "```kō\n{s} : {s}\n```", .{ wi.word, type_str });

            return sendHoverMarkdown(id, gpa, md.items);
        }
    }

    // Fallback: no inferred type (often because the file has errors, e.g.
    // an unresolvable import). Still show the definition's shape from the
    // parse tree so the rest of the file stays navigable.
    if (doc.prog) |prog| {
        for (prog.definitions) |def| {
            const is_match = switch (def) {
                .fn_def => |f| std.mem.eql(u8, wi.word, f.name),
                .type_def => |t| std.mem.eql(u8, wi.word, t.name),
                .let_binding => |l| std.mem.eql(u8, wi.word, l.name),
                .module_def => |m| std.mem.eql(u8, wi.word, m.name),
                else => false,
            };
            if (!is_match) continue;
            var md = try std.ArrayList(u8).initCapacity(gpa, 256);
            defer md.deinit(gpa);
            switch (def) {
                .fn_def => |f| {
                    try md.appendSlice(gpa, "```kō\nfn ");
                    try md.appendSlice(gpa, f.name);
                    for (f.params) |p| {
                        try md.append(gpa, ' ');
                        switch (p.pattern) {
                            .identifier => |n| try md.appendSlice(gpa, n),
                            else => try md.append(gpa, '_'),
                        }
                    }
                    try md.appendSlice(gpa, "\n```");
                },
                .type_def => |t| try md.print(gpa, "```kō\ntype {s}\n```", .{t.name}),
                .let_binding => |l| try md.print(gpa, "```kō\nlet {s}\n```", .{l.name}),
                .module_def => |m| try md.print(gpa, "```kō\nmodule {s}\n```", .{m.name}),
                else => continue,
            }
            const docs: ?[]const []const u8 = switch (def) {
                .fn_def => |f| f.doc_comments,
                .type_def => |t| t.doc_comments,
                .let_binding => |l| l.doc_comments,
                .module_def => |m| m.doc_comments,
                else => null,
            };
            if (docs) |lines| {
                try md.append(gpa, '\n');
                for (lines) |doc_line| {
                    try md.appendSlice(gpa, doc_line);
                    try md.append(gpa, '\n');
                }
            }
            if (doc.parse_error != null or doc.type_error != null) {
                try md.appendSlice(gpa, "\n*No inferred type — the file has errors.*");
            }
            return sendHoverMarkdown(id, gpa, md.items);
        }
        for (prog.imports) |imp| {
            if (imp.path.len == 0) continue;
            const short = imp.path[imp.path.len - 1];
            const matches_alias = if (imp.alias) |a| std.mem.eql(u8, wi.word, a) else false;
            if (!std.mem.eql(u8, wi.word, short) and !matches_alias) continue;
            var md = try std.ArrayList(u8).initCapacity(gpa, 128);
            defer md.deinit(gpa);
            try md.appendSlice(gpa, "```kō\nimport ");
            for (imp.path, 0..) |part, i| {
                if (i > 0) try md.append(gpa, '.');
                try md.appendSlice(gpa, part);
            }
            if (imp.alias) |a| try md.print(gpa, " as {s}", .{a});
            try md.appendSlice(gpa, "\n```");
            return sendHoverMarkdown(id, gpa, md.items);
        }
    }
    return sendNullResult(id, gpa);
}

fn sendCompletionList(id: i64, gpa: std.mem.Allocator) !void {
    return sendResponse(id, "{\"isIncomplete\":false,\"items\":[]}", gpa);
}

fn handleCompletion(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return sendCompletionList(id, gpa);
    const uri = jsonGetString(td, "uri") orelse return sendCompletionList(id, gpa);
    const pos = jsonGetObj(params, "position") orelse return sendCompletionList(id, gpa);
    const line: usize = @intCast(jsonGetInt(pos, "line") orelse 0);
    const char: usize = @intCast(jsonGetInt(pos, "character") orelse 0);

    // The identifier prefix under the cursor drives filtering.
    var prefix: []const u8 = "";
    if (store.get(uri)) |prefix_doc| {
        if (getLine(prefix_doc.text, line)) |line_text| {
            const end = @min(line_text.len, char);
            var start = end;
            while (start > 0 and isIdentChar(line_text[start - 1])) start -= 1;
            prefix = line_text[start..end];
        }
    }

    var body = try std.ArrayList(u8).initCapacity(gpa, 1024);
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"isIncomplete\":false,\"items\":[");

    var first = true;
    var order: usize = 0;
    const emit = struct {
        fn item(b: *std.ArrayList(u8), gpa_inner: std.mem.Allocator, first_inner: *bool, label: []const u8, kind: u8, detail: []const u8, doc: ?[]const u8, rank: usize) !void {
            if (!first_inner.*) try b.append(gpa_inner, ',');
            first_inner.* = false;
            const esc_label = try escapeJsonString(gpa_inner, label);
            defer gpa_inner.free(esc_label);
            const esc_detail = try escapeJsonString(gpa_inner, detail);
            defer gpa_inner.free(esc_detail);
            try b.print(gpa_inner, "{{\"label\":\"{s}\",\"kind\":{d},\"detail\":\"{s}\",\"sortText\":\"{d:0>4}\"", .{ esc_label, kind, esc_detail, rank });
            if (doc) |d| {
                const esc_doc = try escapeJsonString(gpa_inner, d);
                defer gpa_inner.free(esc_doc);
                try b.print(gpa_inner, ",\"documentation\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}", .{esc_doc});
            }
            try b.append(gpa_inner, '}');
        }
    }.item;

    const matches = struct {
        fn prefixMatch(label: []const u8, p: []const u8) bool {
            return p.len == 0 or std.mem.startsWith(u8, label, p);
        }
    }.prefixMatch;

    if (store.get(uri)) |doc| {
        if (doc.prog) |prog| {
            for (prog.definitions) |def| {
                const name, const kind: u8, const detail: []const u8 = switch (def) {
                    .fn_def => |f| .{ f.name, 3, "function" },
                    .type_def => |t| .{ t.name, 8, "type" },
                    .let_binding => |l| .{ l.name, 13, "let binding" },
                    .module_def => |m| .{ m.name, 2, "module" },
                    else => continue,
                };
                if (!matches(name, prefix)) continue;
                try emit(&body, gpa, &first, name, kind, detail, null, order);
                order += 1;
            }
            for (prog.imports) |imp| {
                if (imp.path.len == 0) continue;
                const mod_name = imp.path[imp.path.len - 1];
                if (!matches(mod_name, prefix)) continue;
                try emit(&body, gpa, &first, mod_name, 9, "module", null, order);
                order += 1;
            }
            // Members of imported modules (selective lists respected).
            for (prog.imports) |imp| {
                const short = importShortName(imp) orelse continue;
                const mod = loadImportModule(doc, imp) orelse continue;
                for (mod.program.definitions) |mdef| {
                    const info = defInfo(mdef) orelse continue;
                    if (imp.selective) |sel| {
                        var listed = false;
                        for (sel) |s| {
                            if (std.mem.eql(u8, info.name, s)) {
                                listed = true;
                                break;
                            }
                        }
                        if (!listed) continue;
                    }
                    if (!matches(info.name, prefix)) continue;
                    var detail_buf: [128]u8 = undefined;
                    const detail = std.fmt.bufPrint(&detail_buf, "{s}.{s} (imported)", .{ short, info.name }) catch short;
                    try emit(&body, gpa, &first, info.name, info.kind, detail, null, 500 + order);
                    order += 1;
                }
            }
        }
    }
    for (BUILTIN_DOCS) |b| {
        // Dotted builtins complete on their short name (`toString`).
        const label = if (std.mem.indexOfScalar(u8, b[0], '.')) |dot| b[0][dot + 1 ..] else b[0];
        if (!matches(label, prefix)) continue;
        try emit(&body, gpa, &first, label, 3, b[0], b[1], 1000 + order);
        order += 1;
    }
    for (KEYWORD_DOCS) |k| {
        if (!matches(k[0], prefix)) continue;
        try emit(&body, gpa, &first, k[0], 14, "keyword", k[1], 2000 + order);
        order += 1;
    }

    try body.appendSlice(gpa, "]}");
    const owned = try body.toOwnedSlice(gpa);
    return sendResponse(id, owned, gpa);
}

/// Name, symbol kind, and 1-based definition line for a top-level definition.
const DefInfo = struct { name: []const u8, kind: u8, line: usize };

fn defInfo(def: ast.Definition) ?DefInfo {
    return switch (def) {
        .fn_def => |f| .{ .name = f.name, .kind = 12, .line = f.loc.line },
        .type_def => |t| .{ .name = t.name, .kind = 8, .line = t.loc.line },
        .let_binding => |l| .{ .name = l.name, .kind = 13, .line = l.loc.line },
        .module_def => |m| .{ .name = m.name, .kind = 2, .line = m.loc.line },
        else => null,
    };
}

fn sendEmptyArray(id: i64, gpa: std.mem.Allocator) !void {
    return sendResponse(id, "[]", gpa);
}

fn handleDocumentSymbol(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return sendEmptyArray(id, gpa);
    const uri = jsonGetString(td, "uri") orelse return sendEmptyArray(id, gpa);

    var body = try std.ArrayList(u8).initCapacity(gpa, 512);
    defer body.deinit(gpa);
    try body.append(gpa, '[');

    var first = true;
    if (store.get(uri)) |doc| {
        if (doc.prog) |prog| {
            for (prog.definitions) |def| {
                const info = defInfo(def) orelse continue;
                const def_line: usize = if (info.line > 0) info.line - 1 else 0;
                const line_text = getLine(doc.text, def_line) orelse "";
                // selectionRange covers the name; range covers the whole line.
                var sel_sc: usize = 0;
                var sel_ec: usize = line_text.len;
                if (findDefName(line_text, info.name)) |span| {
                    sel_sc = span.start;
                    sel_ec = span.end;
                }
                if (!first) try body.append(gpa, ',');
                first = false;
                const esc_name = try escapeJsonString(gpa, info.name);
                defer gpa.free(esc_name);
                try body.print(gpa, "{{\"name\":\"{s}\",\"kind\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ esc_name, info.kind, def_line, def_line, line_text.len, def_line, sel_sc, def_line, sel_ec });
            }
            for (prog.imports) |imp| {
                if (imp.path.len == 0 or imp.loc.line == 0) continue;
                const def_line: usize = imp.loc.line - 1;
                const line_text = getLine(doc.text, def_line) orelse "";
                var label = try std.ArrayList(u8).initCapacity(gpa, 64);
                defer label.deinit(gpa);
                try label.appendSlice(gpa, "import ");
                for (imp.path, 0..) |part, i| {
                    if (i > 0) try label.append(gpa, '.');
                    try label.appendSlice(gpa, part);
                }
                const esc_label = try escapeJsonString(gpa, label.items);
                defer gpa.free(esc_label);
                if (!first) try body.append(gpa, ',');
                first = false;
                try body.print(gpa, "{{\"name\":\"{s}\",\"kind\":9,\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"selectionRange\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ esc_label, def_line, def_line, line_text.len, def_line, def_line, line_text.len });
            }
        }
    }

    try body.append(gpa, ']');
    const owned = try body.toOwnedSlice(gpa);
    return sendResponse(id, owned, gpa);
}

fn sendLocation(id: i64, gpa: std.mem.Allocator, uri: []const u8, line: usize, sc: usize, ec: usize) !void {
    const esc_uri = try escapeJsonString(gpa, uri);
    defer gpa.free(esc_uri);
    var body = try std.ArrayList(u8).initCapacity(gpa, 128);
    defer body.deinit(gpa);
    try body.print(gpa, "{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ esc_uri, line, sc, line, ec });
    return sendResponse(id, try body.toOwnedSlice(gpa), gpa);
}

const ImportDefTarget = struct { uri: []const u8, line: usize, sc: usize, ec: usize };

fn loadImportModule(doc: *Document, imp: ast.Import) ?*module_loader_mod.LoadedModule {
    const m = doc.loader.loadModule(imp.path) catch return null;
    return m;
}

/// Short name an import is addressed by: its alias, else its last component.
fn importShortName(imp: ast.Import) ?[]const u8 {
    if (imp.alias) |a| return a;
    if (imp.path.len == 0) return null;
    return imp.path[imp.path.len - 1];
}

fn findDefInModule(gpa: std.mem.Allocator, mod: *module_loader_mod.LoadedModule, word: []const u8) ?ImportDefTarget {
    const uri = std.fmt.allocPrint(gpa, "file://{s}", .{mod.file_path}) catch return null;
    for (mod.program.definitions) |def| {
        const info = defInfo(def) orelse continue;
        if (info.line != 0 and std.mem.eql(u8, word, info.name)) {
            return targetForDef(gpa, uri, mod.source, info.line, info.name);
        }
        // Constructors live inside type definitions; jump to the type.
        if (def == .type_def) {
            const ctors = switch (def.type_def.body) {
                .sum => |cs| cs,
                else => continue,
            };
            for (ctors) |ctor| {
                if (!std.mem.eql(u8, word, ctor.name)) continue;
                if (info.line == 0) return null;
                return targetForDef(gpa, uri, mod.source, info.line, info.name);
            }
        }
    }
    return null;
}

fn targetForDef(gpa: std.mem.Allocator, uri: []const u8, source: []const u8, def_line_1based: usize, name: []const u8) ?ImportDefTarget {
    _ = gpa;
    const def_line: usize = def_line_1based - 1;
    const line_text = getLine(source, def_line) orelse "";
    var sc: usize = 0;
    var ec: usize = line_text.len;
    if (findDefName(line_text, name)) |span| {
        sc = span.start;
        ec = span.end;
    }
    return .{ .uri = uri, .line = def_line, .sc = sc, .ec = ec };
}

fn handleDefinition(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return sendNullResult(id, gpa);
    const uri = jsonGetString(td, "uri") orelse return sendNullResult(id, gpa);
    const pos = jsonGetObj(params, "position") orelse return sendNullResult(id, gpa);
    const line: usize = @intCast(jsonGetInt(pos, "line") orelse 0);
    const char: usize = @intCast(jsonGetInt(pos, "character") orelse 0);
    const doc = store.get(uri) orelse return sendNullResult(id, gpa);
    const wi = getWordAtPosition(doc.text, line, char) orelse return sendNullResult(id, gpa);

    if (doc.prog) |prog| {
        for (prog.definitions) |def| {
            const info = defInfo(def) orelse continue;
            if (std.mem.eql(u8, wi.word, info.name)) {
                if (info.line == 0) return sendNullResult(id, gpa);
                const def_line: usize = info.line - 1;
                const line_text = getLine(doc.text, def_line) orelse "";
                var sel_sc: usize = 0;
                var sel_ec: usize = line_text.len;
                if (findDefName(line_text, info.name)) |span| {
                    sel_sc = span.start;
                    sel_ec = span.end;
                }
                const esc_uri = try escapeJsonString(gpa, uri);
                defer gpa.free(esc_uri);
                var body = try std.ArrayList(u8).initCapacity(gpa, 128);
                defer body.deinit(gpa);
                try body.print(gpa, "{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ esc_uri, def_line, sel_sc, def_line, sel_ec });
                return sendResponse(id, try body.toOwnedSlice(gpa), gpa);
            }
        }
        // Cross-file: qualified `mod.name` access.
        if (getLine(doc.text, line)) |line_text| {
            if (getQualifier(line_text, wi.start)) |modname| {
                for (prog.imports) |imp| {
                    const short = importShortName(imp) orelse continue;
                    if (!std.mem.eql(u8, modname, short)) continue;
                    const mod = loadImportModule(doc, imp) orelse continue;
                    if (findDefInModule(gpa, mod, wi.word)) |t| {
                        return sendLocation(id, gpa, t.uri, t.line, t.sc, t.ec);
                    }
                }
            }
        }
        // Cross-file: selectively imported names, then bare module names.
        for (prog.imports) |imp| {
            if (imp.selective) |sel| {
                for (sel) |s| {
                    if (!std.mem.eql(u8, wi.word, s)) continue;
                    const mod = loadImportModule(doc, imp) orelse continue;
                    if (findDefInModule(gpa, mod, wi.word)) |t| {
                        return sendLocation(id, gpa, t.uri, t.line, t.sc, t.ec);
                    }
                }
            }
            const short = importShortName(imp) orelse continue;
            if (std.mem.eql(u8, wi.word, short)) {
                const mod = loadImportModule(doc, imp) orelse continue;
                const target_uri = try std.fmt.allocPrint(gpa, "file://{s}", .{mod.file_path});
                return sendLocation(id, gpa, target_uri, 0, 0, 0);
            }
        }
    }
    return sendNullResult(id, gpa);
}

fn handleReferences(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return sendEmptyArray(id, gpa);
    const uri = jsonGetString(td, "uri") orelse return sendEmptyArray(id, gpa);
    const pos = jsonGetObj(params, "position") orelse return sendEmptyArray(id, gpa);
    const line: usize = @intCast(jsonGetInt(pos, "line") orelse 0);
    const char: usize = @intCast(jsonGetInt(pos, "character") orelse 0);
    const doc = store.get(uri) orelse return sendEmptyArray(id, gpa);
    const wi = getWordAtPosition(doc.text, line, char) orelse return sendEmptyArray(id, gpa);

    const esc_uri = try escapeJsonString(gpa, uri);
    defer gpa.free(esc_uri);

    var body = try std.ArrayList(u8).initCapacity(gpa, 512);
    defer body.deinit(gpa);
    try body.append(gpa, '[');

    var first = true;
    var lineno: usize = 0;
    var remaining: []const u8 = doc.text;
    while (remaining.len > 0) {
        const nl = std.mem.indexOfScalar(u8, remaining, '\n');
        const line_text = if (nl) |idx| remaining[0..idx] else remaining;
        // Skip comment-only lines so `# mentions` are not reported.
        const trimmed = std.mem.trimStart(u8, line_text, " \t");
        if (trimmed.len == 0 or trimmed[0] != '#') {
            var i: usize = 0;
            while (i + wi.word.len <= line_text.len) {
                if (std.mem.eql(u8, line_text[i .. i + wi.word.len], wi.word)) {
                    const before_ok = i == 0 or !isIdentChar(line_text[i - 1]);
                    const after = i + wi.word.len;
                    const after_ok = after >= line_text.len or !isIdentChar(line_text[after]);
                    if (before_ok and after_ok) {
                        if (!first) try body.append(gpa, ',');
                        first = false;
                        try body.print(gpa, "{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ esc_uri, lineno, i, lineno, after });
                        i = after;
                        continue;
                    }
                }
                i += 1;
            }
        }
        if (nl == null) break;
        remaining = remaining[nl.? + 1 ..];
        lineno += 1;
    }

    try body.append(gpa, ']');
    const owned = try body.toOwnedSlice(gpa);
    return sendResponse(id, owned, gpa);
}

fn escapeJsonString(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(alloc, s.len);
    errdefer result.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(alloc, "\\\""),
            '\\' => try result.appendSlice(alloc, "\\\\"),
            '\n' => try result.appendSlice(alloc, "\\n"),
            '\r' => try result.appendSlice(alloc, "\\r"),
            '\t' => try result.appendSlice(alloc, "\\t"),
            else => try result.append(alloc, c),
        }
    }
    return result.toOwnedSlice(alloc);
}

fn appendDiag(gpa: std.mem.Allocator, body: *std.ArrayList(u8), first: *bool, severity: u8, sl: usize, sc: usize, el: usize, ec_pos: usize, escaped: []const u8) !void {
    if (!first.*) try body.append(gpa, ',');
    first.* = false;
    try body.appendSlice(gpa, "{\"range\":{\"start\":{\"line\":");
    var num_buf: [20]u8 = undefined;
    try body.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{sl}));
    try body.appendSlice(gpa, ",\"character\":");
    try body.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{sc}));
    try body.appendSlice(gpa, "},\"end\":{\"line\":");
    try body.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{el}));
    try body.appendSlice(gpa, ",\"character\":");
    try body.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{ec_pos}));
    try body.appendSlice(gpa, "}},\"severity\":");
    try body.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{severity}));
    try body.appendSlice(gpa, ",\"message\":\"");
    try body.appendSlice(gpa, escaped);
    try body.appendSlice(gpa, "\"}");
}

fn publishDiagnostics(store: *DocumentStore, uri: []const u8, gpa: std.mem.Allocator) !void {
    const doc = store.get(uri) orelse return;

    var body = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"uri\":\"");
    try body.appendSlice(gpa, uri);
    try body.appendSlice(gpa, "\",\"diagnostics\":[");

    var first = true;
    if (doc.parse_error) |err| {
        const escaped = try escapeJsonString(gpa, err);
        defer gpa.free(escaped);
        const loc = doc.parse_error_loc orelse ast.Loc{};
        const sl: usize = if (loc.line > 0) loc.line - 1 else 0;
        const sc: usize = if (loc.col > 0) loc.col - 1 else 0;
        const el: usize = if (loc.end_line > 0) loc.end_line - 1 else sl;
        const ec_pos: usize = if (loc.end_col > 0) loc.end_col - 1 else sc;
        try appendDiag(gpa, &body, &first, 1, sl, sc, el, ec_pos, escaped);
    }
    // The checker collects per-definition errors; when it does, those
    // (with their own locations) replace the single-error fallback below.
    for (doc.diag_list.items.items) |d| {
        var full_msg = try std.ArrayList(u8).initCapacity(gpa, d.message.len + 64);
        defer full_msg.deinit(gpa);
        try full_msg.appendSlice(gpa, d.message);
        if (d.note) |note| {
            try full_msg.appendSlice(gpa, " — ");
            try full_msg.appendSlice(gpa, note);
        }
        const escaped = try escapeJsonString(gpa, full_msg.items);
        defer gpa.free(escaped);
        const loc = d.loc orelse ast.Loc{};
        const sl: usize = if (loc.line > 0) loc.line - 1 else 0;
        const sc: usize = if (loc.col > 0) loc.col - 1 else 0;
        const el: usize = if (loc.end_line > 0) loc.end_line - 1 else sl;
        const ec_pos: usize = if (loc.end_col > 0) loc.end_col - 1 else sc;
        const severity: u8 = if (d.severity == .@"error") 1 else 2;
        try appendDiag(gpa, &body, &first, severity, sl, sc, el, ec_pos, escaped);
    }
    if (doc.type_error) |err| {
        if (doc.diag_list.items.items.len == 0) {
            // Surface the expected/actual types when the checker provides them.
            var full_msg = try std.ArrayList(u8).initCapacity(gpa, err.len + 64);
            defer full_msg.deinit(gpa);
            try full_msg.appendSlice(gpa, err);
            if (doc.type_error_expected) |exp| {
                if (doc.type_error_actual) |act| {
                    if (std.mem.indexOf(u8, err, "expected") == null) {
                        try full_msg.print(gpa, " (expected {s}, got {s})", .{ exp, act });
                    }
                }
            }
            const escaped = try escapeJsonString(gpa, full_msg.items);
            defer gpa.free(escaped);
            const loc = doc.type_error_loc orelse ast.Loc{};
            const sl: usize = if (loc.line > 0) loc.line - 1 else 0;
            const sc: usize = if (loc.col > 0) loc.col - 1 else 0;
            const el: usize = if (loc.end_line > 0) loc.end_line - 1 else sl;
            const ec_pos: usize = if (loc.end_col > 0) loc.end_col - 1 else sc;
            try appendDiag(gpa, &body, &first, 1, sl, sc, el, ec_pos, escaped);
        }
    }

    try body.appendSlice(gpa, "]}");
    const owned = try body.toOwnedSlice(gpa);
    return sendNotification("textDocument/publishDiagnostics", owned, gpa);
}

//
// Main
//

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const allocator = gpa;

    var threaded: Io.Threaded = .init(gpa, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Resolve the stdlib once, the same way `ko --check` does:
    // KO_STDLIB_PATH wins, otherwise the binary's own directory
    // (symlinks resolved, so exe_dir/../../std finds a repo checkout).
    const exe_dir = std.process.executableDirPathAlloc(io, init.arena.allocator()) catch null;
    const stdlib_override: ?[]const u8 = if (std.c.getenv("KO_STDLIB_PATH")) |p| std.mem.span(p) else null;

    var store = DocumentStore.init(allocator, exe_dir, stdlib_override);
    defer store.deinit();

    var initialized = false;

    while (true) {
        var msg_arena = std.heap.ArenaAllocator.init(allocator);
        defer msg_arena.deinit();
        const msg_alloc = msg_arena.allocator();

        const content_length = readContentLength() catch |err| {
            if (err == error.ConnectionClosed) break;
            return err;
        };

        const msg_buf = msg_alloc.alloc(u8, content_length) catch continue;
        readExact(msg_buf) catch continue;

        const parsed = std.json.parseFromSlice(JsonValue, msg_alloc, msg_buf, .{}) catch continue;
        defer parsed.deinit();
        const msg = parsed.value;

        const method = jsonGetString(msg, "method") orelse continue;
        const id_val = jsonGetInt(msg, "id");
        const id = id_val orelse 0;
        const params = jsonGetObj(msg, "params") orelse JsonValue{ .null = {} };

        if (std.mem.eql(u8, method, "initialize")) {
            const body = try msg_alloc.dupe(u8, initialize_result);
            try sendResponse(id, body, msg_alloc);
            initialized = true;
        } else if (std.mem.eql(u8, method, "initialized")) {
            // no response
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try sendNullResult(id, msg_alloc);
        } else if (std.mem.eql(u8, method, "exit")) {
            break;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try handleTextDocumentDidOpen(&store, params);
            if (initialized) {
                const td = jsonGetObj(params, "textDocument") orelse continue;
                const uri = jsonGetString(td, "uri") orelse continue;
                try publishDiagnostics(&store, uri, msg_alloc);
            }
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try handleTextDocumentDidChange(&store, params);
            if (initialized) {
                const td = jsonGetObj(params, "textDocument") orelse continue;
                const uri = jsonGetString(td, "uri") orelse continue;
                try publishDiagnostics(&store, uri, msg_alloc);
            }
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try handleTextDocumentDidClose(&store, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try handleHover(id, &store, params, msg_alloc);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try handleCompletion(id, &store, params, msg_alloc);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try handleDefinition(id, &store, params, msg_alloc);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try handleReferences(id, &store, params, msg_alloc);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try handleDocumentSymbol(id, &store, params, msg_alloc);
        }
    }
}

fn handleTextDocumentDidOpen(store: *DocumentStore, params: JsonValue) !void {
    const td = jsonGetObj(params, "textDocument") orelse return;
    const uri = jsonGetString(td, "uri") orelse return;
    const text = jsonGetString(td, "text") orelse return;
    const version: i32 = @intCast(jsonGetInt(td, "version") orelse 0);
    _ = try store.open(uri, text, version);
}

fn handleTextDocumentDidChange(store: *DocumentStore, params: JsonValue) !void {
    const td = jsonGetObj(params, "textDocument") orelse return;
    const uri = jsonGetString(td, "uri") orelse return;
    const version: i32 = @intCast(jsonGetInt(td, "version") orelse 0);
    const changes = jsonGetObj(params, "contentChanges") orelse return;
    if (changes != .array or changes.array.items.len == 0) return;
    const text = jsonGetString(changes.array.items[0], "text") orelse return;
    try store.update(uri, text, version);
}

fn handleTextDocumentDidClose(store: *DocumentStore, params: JsonValue) !void {
    const td = jsonGetObj(params, "textDocument") orelse return;
    const uri = jsonGetString(td, "uri") orelse return;
    store.close(uri);
}
