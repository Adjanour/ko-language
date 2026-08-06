const std = @import("std");
const parser = @import("parser.zig");

pub const Severity = enum { @"error", warning, note, help };

pub const WarningKind = enum(u32) {
    unused_variable = 1,
    unused_import = 2,
    shadowed_variable = 4,
    exhaustive_match = 8,
};

pub const WarningSet = struct {
    bits: u32 = 0,

    pub fn isEmpty(self: WarningSet) bool {
        return self.bits == 0;
    }

    pub fn contains(self: WarningSet, kind: WarningKind) bool {
        return (self.bits & @intFromEnum(kind)) != 0;
    }

    pub fn add(self: *WarningSet, kind: WarningKind) void {
        self.bits |= @intFromEnum(kind);
    }

    pub fn all() WarningSet {
        return .{ .bits = 0xFFFFFFFF };
    }

    pub fn fromName(name: []const u8) ?WarningSet {
        if (std.mem.eql(u8, name, "all")) return all();
        if (std.mem.eql(u8, name, "unused")) return .{ .bits = @intFromEnum(WarningKind.unused_variable) | @intFromEnum(WarningKind.unused_import) };
        if (std.mem.eql(u8, name, "unused-variable")) return .{ .bits = @intFromEnum(WarningKind.unused_variable) };
        if (std.mem.eql(u8, name, "unused-import")) return .{ .bits = @intFromEnum(WarningKind.unused_import) };
        if (std.mem.eql(u8, name, "shadow")) return .{ .bits = @intFromEnum(WarningKind.shadowed_variable) };
        if (std.mem.eql(u8, name, "exhaustive-match")) return .{ .bits = @intFromEnum(WarningKind.exhaustive_match) };
        return null;
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    loc: ?parser.Loc = null,
    context: ?[]const u8 = null,
    note: ?[]const u8 = null,
    help: ?[]const u8 = null,
};

pub const DiagnosticList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,
    has_errors: bool = false,

    pub fn init(allocator: std.mem.Allocator) DiagnosticList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DiagnosticList) void {
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *DiagnosticList, diag: Diagnostic) !void {
        try self.items.append(self.allocator, diag);
        if (diag.severity == .@"error") self.has_errors = true;
    }

    pub fn addError(self: *DiagnosticList, message: []const u8, loc: ?parser.Loc) !void {
        try self.add(.{ .severity = .@"error", .message = message, .loc = loc });
    }

    pub fn addErrorCtx(self: *DiagnosticList, message: []const u8, loc: ?parser.Loc, note: ?[]const u8, help: ?[]const u8) !void {
        try self.add(.{ .severity = .@"error", .message = message, .loc = loc, .note = note, .help = help });
    }

    pub fn addWarning(self: *DiagnosticList, message: []const u8, loc: ?parser.Loc) !void {
        try self.add(.{ .severity = .warning, .message = message, .loc = loc });
    }

    pub fn addWarningCtx(self: *DiagnosticList, message: []const u8, loc: ?parser.Loc, note: ?[]const u8, help: ?[]const u8) !void {
        try self.add(.{ .severity = .warning, .message = message, .loc = loc, .note = note, .help = help });
    }

    pub fn emitAll(self: *DiagnosticList, io: anytype, filename: []const u8, source: []const u8) void {
        for (self.items.items) |diag| {
            emitDiagnostic(io, filename, source, diag);
        }
    }

    pub fn hasFatalErrors(self: *const DiagnosticList) bool {
        return self.has_errors;
    }
};

pub const Color = struct {
    // ANSI escape codes
    pub const reset = "\x1b[0m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
    pub const green = "\x1b[32m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const white = "\x1b[37m";
    pub const bright_red = "\x1b[91m";
    pub const bright_yellow = "\x1b[93m";
    pub const bright_cyan = "\x1b[96m";
};

var use_color: ?bool = null;

pub fn shouldUseColor() bool {
    if (use_color) |c| return c;
    // Check if stderr is a TTY using libc isatty
    const is_tty = std.c.isatty(std.posix.STDERR_FILENO) != 0;
    use_color = is_tty;
    return is_tty;
}

fn severityLabel(sev: Severity) struct { text: []const u8, color: []const u8 } {
    return switch (sev) {
        .@"error" => .{ .text = "error", .color = Color.bright_red },
        .warning => .{ .text = "warning", .color = Color.bright_yellow },
        .note => .{ .text = "note", .color = Color.bright_cyan },
        .help => .{ .text = "help", .color = Color.green },
    };
}

fn emitDiagnostic(io: anytype, filename: []const u8, source: []const u8, diag: Diagnostic) void {
    const stderr = @import("std").Io.File.stderr();
    var buffer: [4096]u8 = undefined;
    var w = stderr.writer(io, &buffer);
    const color = shouldUseColor();
    const sev = severityLabel(diag.severity);

    // Header line: error at file:line:col: message
    if (color) w.interface.print("{s}{s}{s}", .{ sev.color, Color.bold, sev.text }) catch {};
    if (diag.loc) |l| {
        w.interface.print(" at {s}:{d}:{d}", .{ filename, l.line, l.col }) catch {};
    }
    if (color) w.interface.print("{s}: ", .{Color.reset}) catch {} else {
        w.interface.print(": ", .{}) catch {};
    }
    w.interface.print("{s}\n", .{diag.message}) catch {};

    // Source line with caret
    if (diag.loc) |l| {
        emitSourceLine(&w, filename, source, l, color);
    }

    // Context line (e.g., "while typechecking function foo")
    if (diag.context) |ctx| {
        if (color) w.interface.print("  {s}{s}{s}", .{ Color.dim, Color.bold, Color.bright_cyan }) catch {};
        w.interface.print("  = {s}", .{ctx}) catch {};
        if (color) w.interface.print("{s}\n", .{Color.reset}) catch {} else {
            w.interface.print("\n", .{}) catch {};
        }
    }

    // Note
    if (diag.note) |note| {
        if (color) w.interface.print("{s}{s}{s}", .{ Color.bright_cyan, Color.bold, Color.dim }) catch {};
        if (diag.loc) |l| {
            w.interface.print("  note at {s}:{d}:{d}: ", .{ filename, l.line, l.col }) catch {};
        } else {
            w.interface.print("  note: ", .{}) catch {};
        }
        if (color) w.interface.print("{s}{s}", .{Color.reset, Color.dim}) catch {};
        w.interface.print("{s}", .{note}) catch {};
        if (color) w.interface.print("{s}\n", .{Color.reset}) catch {} else {
            w.interface.print("\n", .{}) catch {};
        }
    }

    // Help
    if (diag.help) |help| {
        if (color) w.interface.print("{s}{s}{s}", .{ Color.green, Color.bold, Color.dim }) catch {};
        if (diag.loc) |l| {
            w.interface.print("  help at {s}:{d}:{d}: ", .{ filename, l.line, l.col }) catch {};
        } else {
            w.interface.print("  help: ", .{}) catch {};
        }
        if (color) w.interface.print("{s}{s}", .{Color.reset, Color.dim}) catch {};
        w.interface.print("{s}", .{help}) catch {};
        if (color) w.interface.print("{s}\n", .{Color.reset}) catch {} else {
            w.interface.print("\n", .{}) catch {};
        }
    }

    w.interface.flush() catch {};
}

fn emitSourceLine(w: anytype, _: []const u8, source: []const u8, loc: parser.Loc, color: bool) void {
    // Find the line in source
    var line_num: usize = 1;
    var line_start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            if (line_num == loc.line) {
                const line_end = i;
                const line_content = source[line_start..line_end];

                // Line number gutter
                if (color) w.interface.print("  {s}{d}{s} | ", .{ Color.dim, loc.line, Color.reset }) catch {};
                w.interface.print("  {d} | ", .{loc.line}) catch {};

                // Source line
                w.interface.print("{s}\n", .{line_content}) catch {};

                // Caret underline
                w.interface.print("  ", .{}) catch {};
                var j: usize = 0;
                while (j < std.fmt.count("{d}", .{loc.line}) + 4) : (j += 1) {
                    w.interface.print(" ", .{}) catch {};
                }
                var col: usize = 1;
                while (col < loc.col) : (col += 1) {
                    w.interface.print(" ", .{}) catch {};
                }
                if (color) w.interface.print("{s}{s}^{s}\n", .{ Color.bright_red, Color.bold, Color.reset }) catch {};
                w.interface.print("^\n", .{}) catch {};
                return;
            }
            line_num += 1;
            line_start = i + 1;
        }
    }
}
