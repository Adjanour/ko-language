//! Windows fallback for linenoise (vendor/linenoise.c is POSIX-only and is
//! not compiled on Windows). Provides the same API surface as `linenoise.zig`
//! so `repl.zig` can import either transparently.
//!
//! MVP scope: prompt + line read from stdin, in-memory history with file
//! persistence. No raw-mode key handling or interactive completion.

const std = @import("std");
const fdio = @import("fdio.zig");

pub const Completions = extern struct {
    len: usize,
    cvec: [*c][*c]u8,
};

pub const CompletionCallback = *const fn ([*:0]const u8, *Completions) callconv(.c) void;

var g_history: std.ArrayList([:0]const u8) = .empty;
var g_history_max_len: usize = 1000;
var g_completion_cb: ?CompletionCallback = null;

pub fn linenoise(prompt: [*:0]const u8) ?[*:0]u8 {
    const prompt_slice = std.mem.sliceTo(prompt, 0);
    _ = fdio.write(fdio.stdout, prompt_slice);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.heap.c_allocator);

    var chunk: [256]u8 = undefined;
    var eof = true;
    while (true) {
        const rc = fdio.read(fdio.stdin, &chunk);
        if (rc <= 0) break;
        const n: usize = @intCast(rc);
        eof = false;
        var consumed: usize = 0;
        while (consumed < n) : (consumed += 1) {
            const ch = chunk[consumed];
            if (ch == '\n') {
                buf.append(std.heap.c_allocator, '\n') catch {};
                consumed += 1;
                break;
            }
            buf.append(std.heap.c_allocator, ch) catch {};
        }
        if (consumed < n) break; // newline consumed; stop reading
    }

    if (eof) return null;

    // Strip CRLF (\r\n) and LF (\n) line endings.
    if (buf.items.len >= 1 and buf.items[buf.items.len - 1] == '\n') {
        buf.items.len -= 1;
    }
    if (buf.items.len >= 1 and buf.items[buf.items.len - 1] == '\r') {
        buf.items.len -= 1;
    }

    return std.heap.c_allocator.dupeZ(u8, buf.items) catch null;
}

pub fn linenoiseFree(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        const ptr_to_u8: [*]u8 = @ptrCast(@alignCast(p));
        // c_allocator.free ignores the slice length and frees via libc free().
        std.heap.c_allocator.free(ptr_to_u8[0..0]);
    }
}

pub fn linenoiseHistoryAdd(line: [*:0]const u8) c_int {
    const entry = std.mem.sliceTo(line, 0);
    if (g_history.items.len > 0 and std.mem.eql(u8, g_history.items[g_history.items.len - 1], entry)) {
        return 0;
    }
    const duped = std.heap.c_allocator.dupeZ(u8, entry) catch return 1;
    g_history.append(std.heap.c_allocator, duped) catch {
        std.heap.c_allocator.free(duped);
        return 1;
    };
    if (g_history.items.len > g_history_max_len) {
        const removed = g_history.orderedRemove(0);
        std.heap.c_allocator.free(removed);
    }
    return 0;
}

pub fn linenoiseHistorySetMaxLen(len: c_int) c_int {
    g_history_max_len = if (len < 0) 0 else @intCast(len);
    while (g_history.items.len > g_history_max_len) {
        const removed = g_history.orderedRemove(0);
        std.heap.c_allocator.free(removed);
    }
    return 1;
}

pub fn linenoiseHistorySave(filename: [*:0]const u8) c_int {
    const file = std.fs.cwd().createFile(std.mem.sliceTo(filename, 0), .{}) catch return 1;
    defer file.close();
    var buf_writer = std.io.bufferedWriter(file.writer());
    const w = buf_writer.writer();
    for (g_history.items) |entry| {
        w.print("{s}\n", .{entry}) catch return 1;
    }
    buf_writer.flush() catch return 1;
    return 0;
}

pub fn linenoiseHistoryLoad(filename: [*:0]const u8) c_int {
    const file = std.fs.cwd().openFile(std.mem.sliceTo(filename, 0), .{}) catch return 1;
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    const r = buf_reader.reader();
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(std.heap.c_allocator);
    while (true) {
        line_buf.clearRetainingCapacity();
        r.streamUntilDelimiter(std.heap.c_allocator, &line_buf, '\n', null) catch break;
        if (line_buf.items.len > 0 and line_buf.items[line_buf.items.len - 1] == '\r') {
            line_buf.items.len -= 1;
        }
        const duped = std.heap.c_allocator.dupeZ(u8, line_buf.items) catch break;
        g_history.append(std.heap.c_allocator, duped) catch {
            std.heap.c_allocator.free(duped);
            break;
        };
    }
    return 0;
}

pub fn linenoiseSetMultiLine(ml: c_int) void {
    _ = ml;
}

pub fn linenoiseSetCompletionCallback(cb: CompletionCallback) void {
    g_completion_cb = cb;
}

pub fn linenoiseAddCompletion(completions: *Completions, str: [*:0]const u8) void {
    _ = completions;
    _ = str;
}

pub fn historyAdd(line: [*:0]const u8) c_int {
    return linenoiseHistoryAdd(line);
}

pub fn historySetMaxLen(len: c_int) c_int {
    return linenoiseHistorySetMaxLen(len);
}

pub fn historySave(filename: [*:0]const u8) c_int {
    return linenoiseHistorySave(filename);
}

pub fn historyLoad(filename: [*:0]const u8) c_int {
    return linenoiseHistoryLoad(filename);
}

pub fn setMultiLine(ml: c_int) void {
    linenoiseSetMultiLine(ml);
}

pub fn setCompletionCallback(cb: CompletionCallback) void {
    linenoiseSetCompletionCallback(cb);
}

pub fn addCompletion(completions: *Completions, str: [*:0]const u8) void {
    linenoiseAddCompletion(completions, str);
}

pub fn clearScreen() void {}
