const std = @import("std");
const linux = std.os.linux;
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const typecheck_mod = @import("typecheck.zig");

const JsonValue = std.json.Value;

// Document Store
//
const Document = struct {
    uri: []const u8,
    text: []const u8,
    source_z: ?[]const u8,
    version: i32,
    prog: ?ast.Program,
    inferer: ?typecheck_mod.Inferer,
    parse_error: ?[]const u8,
    type_error: ?[]const u8,
};

const DocumentStore = struct {
    documents: std.StringHashMap(Document),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{
            .documents = std.StringHashMap(Document).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *DocumentStore) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.freeDocument(entry.value_ptr);
        }
        self.documents.deinit();
    }

    fn freeDocument(self: *DocumentStore, doc: *Document) void {
        if (doc.inferer) |*inf| inf.deinit();
        if (doc.prog) |*p| typecheck_mod.deallocProg(self.allocator, p);
        if (doc.parse_error) |e| self.allocator.free(e);
        if (doc.type_error) |e| self.allocator.free(e);
        if (doc.source_z) |sz| self.allocator.free(sz.ptr[0..sz.len + 1]);
        self.allocator.free(doc.text);
    }

    fn open(self: *DocumentStore, uri: []const u8, text: []const u8, version: i32) !*Document {
        const owned_uri = try self.allocator.dupe(u8, uri);
        const owned_text = try self.allocator.dupe(u8, text);
        const result = try self.documents.getOrPut(owned_uri);
        if (result.found_existing) self.freeDocument(result.value_ptr);
        result.value_ptr.* = .{
            .uri = owned_uri,
            .text = owned_text,
            .source_z = null,
            .version = version,
            .prog = null,
            .inferer = null,
            .parse_error = null,
            .type_error = null,
        };
        self.analyze(result.value_ptr);
        return result.value_ptr;
    }

    fn update(self: *DocumentStore, uri: []const u8, text: []const u8, version: i32) !void {
        const entry = self.documents.getEntry(uri) orelse return;
        self.freeDocument(entry.value_ptr);
        const owned_text = try self.allocator.dupe(u8, text);
        entry.value_ptr.* = .{
            .uri = entry.value_ptr.uri,
            .text = owned_text,
            .source_z = null,
            .version = version,
            .prog = null,
            .inferer = null,
            .parse_error = null,
            .type_error = null,
        };
        self.analyze(entry.value_ptr);
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
        const source_z = self.allocator.dupeZ(u8, doc.text) catch return;
        var p = parser.Parser.init(self.allocator, source_z) catch |err| {
            doc.parse_error = std.fmt.allocPrint(self.allocator, "Parse init error: {}", .{err}) catch null;
            self.allocator.free(source_z);
            return;
        };
        defer p.deinit();
        const prog = p.parse_program() catch |err| {
            doc.parse_error = std.fmt.allocPrint(self.allocator, "Parse error: {}", .{err}) catch null;
            self.allocator.free(source_z);
            return;
        };
        doc.source_z = source_z;
        doc.prog = prog;
        var inferer = typecheck_mod.Inferer.init(self.allocator);
        inferer.inferProgram(&prog) catch |err| {
            if (inferer.last_error) |ec| {
                doc.type_error = ec.message;
                if (ec.expected) |e| self.allocator.free(e);
                if (ec.actual) |a| self.allocator.free(a);
            } else {
                doc.type_error = std.fmt.allocPrint(self.allocator, "Type error: {}", .{err}) catch null;
            }
            inferer.deinit();
            return;
        };
        doc.inferer = inferer;
    }
};

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
// LSP I/O — raw Linux syscalls (std.Io doesn't work with pipes)
//

fn rawRead(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
        return switch (e) {
            .INTR => rawRead(fd, buf),
            else => error.ReadFailed,
        };
    }
    if (rc == 0) return error.EndOfStream;
    return @intCast(rc);
}

fn rawReadExact(fd: i32, buf: []u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try rawRead(fd, buf[pos..]);
        pos += n;
    }
}

fn readLine(fd: i32, line_buf: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < line_buf.len) {
        const n = rawRead(fd, line_buf[line_len .. line_len + 1]) catch |err| {
            if (err == error.EndOfStream) return error.ConnectionClosed;
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
        const line = readLine(linux.STDIN_FILENO, &line_buf) catch {
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
    try rawReadExact(linux.STDIN_FILENO, buf);
}

fn writeAll(fd: i32, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = linux.write(fd, data[pos..].ptr, data.len - pos);
        if (rc < 0) {
            const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
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
    try writeAll(linux.STDOUT_FILENO, header);
    try writeAll(linux.STDOUT_FILENO, msg);
}

fn sendNullResult(id: i64, gpa: std.mem.Allocator) !void {
    return sendResponse(id, "{\"result\":null}", gpa);
}

fn sendNotification(method: []const u8, params_json: []const u8, gpa: std.mem.Allocator) !void {
    const msg = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
    defer gpa.free(msg);
    const header = try std.fmt.allocPrint(gpa, "Content-Length: {d}\r\n\r\n", .{msg.len});
    defer gpa.free(header);
    try writeAll(linux.STDOUT_FILENO, header);
    try writeAll(linux.STDOUT_FILENO, msg);
}

//
// Helpers
//

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn getWordAtPosition(text: []const u8, line: usize, character: usize) ?struct { word: []const u8 } {
    var current_line: usize = 0;
    var line_start: usize = 0;
    for (text, 0..) |c, i| {
        if (current_line == line) {
            const line_text = text[line_start..];
            const pos = @min(line_text.len, character);
            if (pos >= line_text.len) return null;
            var start = pos;
            while (start > 0 and isIdentChar(line_text[start - 1])) start -= 1;
            var end = pos;
            while (end < line_text.len and isIdentChar(line_text[end])) end += 1;
            if (start >= end) return null;
            return .{ .word = line_text[start..end] };
        }
        if (c == '\n') {
            current_line += 1;
            line_start = i + 1;
        }
    }
    return null;
}

//
// Constants
//

const initialize_result =
    \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"hoverProvider":true,"completionProvider":{"triggerCharacters":["."]},"definitionProvider":true,"documentSymbolProvider":true}}
;

const KEYWORDS = [_][]const u8{
    "fn",      "let",    "if", "then", "else",     "match", "in",
    "type",    "import", "as", "ref",  "comptime", "pub",   "module",
    "package", "and",    "or", "not",  "true",     "false",
};

const BUILTINS = [_][]const u8{
    "println", "print", "inspect", "length", "head",
    "tail",    "cons",  "empty",   "map",    "filter",
    "fold",    "add",   "sub",     "mul",    "div",
};

//
// Handlers
//

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
            const body = try std.fmt.allocPrint(gpa, "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"**{s}**: {s}\"}}}}", .{ b[0], b[1] });
            return sendResponse(id, body, gpa);
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

            try md.print(gpa, "```kō\\n{s} : {s}\\n```", .{ wi.word, type_str });

            var body = try std.ArrayList(u8).initCapacity(gpa, 256);
            defer body.deinit(gpa);
            const escaped = try escapeJsonString(gpa, md.items);
            defer gpa.free(escaped);
            try body.print(gpa, "{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"{s}\"}}}}", .{escaped});
            return sendResponse(id, try body.toOwnedSlice(gpa), gpa);
        }
    }
    return sendNullResult(id, gpa);
}

fn handleCompletion(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return;
    const uri = jsonGetString(td, "uri") orelse return;

    var body = try std.ArrayList(u8).initCapacity(gpa, 1024);
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"isIncomplete\":false,\"items\":[");

    var first = true;
    for (KEYWORDS) |kw| {
        if (!first) try body.append(gpa, ',');
        first = false;
        try body.print(gpa, "{{\"label\":\"{s}\",\"kind\":14}}", .{kw});
    }
    for (BUILTINS) |bi| {
        if (!first) try body.append(gpa, ',');
        first = false;
        try body.print(gpa, "{{\"label\":\"{s}\",\"kind\":12}}", .{bi});
    }

    if (store.get(uri)) |doc| {
        if (doc.prog) |prog| {
            for (prog.definitions) |def| {
                const name, const kind: u8 = switch (def) {
                    .fn_def => |f| .{ f.name, 3 },
                    .type_def => |t| .{ t.name, 23 },
                    .let_binding => |l| .{ l.name, 13 },
                    .module_def => |m| .{ m.name, 2 },
                    else => continue,
                };
                if (!first) try body.append(gpa, ',');
                first = false;
                try body.print(gpa, "{{\"label\":\"{s}\",\"kind\":{d}}}", .{ name, kind });
            }
        }
    }

    try body.appendSlice(gpa, "]}");
    const owned = try body.toOwnedSlice(gpa);
    return sendResponse(id, owned, gpa);
}

fn handleDocumentSymbol(id: i64, store: *DocumentStore, params: JsonValue, gpa: std.mem.Allocator) !void {
    const td = jsonGetObj(params, "textDocument") orelse return;
    const uri = jsonGetString(td, "uri") orelse return;

    var body = try std.ArrayList(u8).initCapacity(gpa, 512);
    defer body.deinit(gpa);
    try body.append(gpa, '[');

    var first = true;
    if (store.get(uri)) |doc| {
        if (doc.prog) |prog| {
            for (prog.definitions) |def| {
                const name, const kind: u8 = switch (def) {
                    .fn_def => |f| .{ f.name, 12 },
                    .type_def => |t| .{ t.name, 23 },
                    .let_binding => |l| .{ l.name, 13 },
                    .module_def => |m| .{ m.name, 2 },
                    else => continue,
                };
                if (!first) try body.append(gpa, ',');
                first = false;
                try body.print(gpa, "{{\"name\":\"{s}\",\"kind\":{d},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"selectionRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}}}}", .{ name, kind });
            }
        }
    }

    try body.append(gpa, ']');
    const owned = try body.toOwnedSlice(gpa);
    return sendResponse(id, owned, gpa);
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
            const name = switch (def) {
                .fn_def => |f| f.name,
                .type_def => |t| t.name,
                .let_binding => |l| l.name,
                .module_def => |m| m.name,
                else => continue,
            };
            if (std.mem.eql(u8, wi.word, name)) {
                const body = try std.fmt.allocPrint(gpa, "{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}}}}", .{uri});
                return sendResponse(id, body, gpa);
            }
        }
    }
    return sendNullResult(id, gpa);
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

fn publishDiagnostics(store: *DocumentStore, uri: []const u8, gpa: std.mem.Allocator) !void {
    const doc = store.get(uri) orelse return;

    var body = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer body.deinit(gpa);
    try body.print(gpa, "{{\"uri\":\"{s}\",\"diagnostics\":[", .{uri});

    var first = true;
    if (doc.parse_error) |err| {
        const escaped = try escapeJsonString(gpa, err);
        defer gpa.free(escaped);
        try body.print(gpa, "{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"severity\":1,\"message\":\"{s}\"}}", .{escaped});
        first = false;
    }
    if (doc.type_error) |err| {
        if (!first) try body.append(gpa, ',');
        const escaped = try escapeJsonString(gpa, err);
        defer gpa.free(escaped);
        try body.print(gpa, "{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"severity\":1,\"message\":\"{s}\"}}", .{escaped});
    }

    try body.appendSlice(gpa, "]}");
    const owned = try body.toOwnedSlice(gpa);
    return sendNotification("textDocument/publishDiagnostics", owned, gpa);
}

//
// Main
//

pub fn main(_: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = DocumentStore.init(allocator);
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
