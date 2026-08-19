// stdlib.zig — Kō standard library implementations in Zig
//
// This is the canonical implementation for all stdlib builtins.
// For JIT mode: codegen.zig maps LLVM declarations to these functions.
// For JIT mode: LLVM codegen uses these directly via global mapping.

const std = @import("std");

// ============================================================
// Integer operations
// ============================================================

pub fn ko_int_to_string(val: i64) callconv(.c) ?[*:0]const u8 {
    const buf = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{val}) catch return null;
    return @ptrCast(buf.ptr);
}

pub fn ko_int_pow(base: i64, exp: i64) callconv(.c) i64 {
    if (exp < 0) return 0;
    var result: i64 = 1;
    var b = base;
    var e = exp;
    while (e > 0) {
        if (e & 1 != 0) result *= b;
        b *= b;
        e >>= 1;
    }
    return result;
}

pub fn ko_int_gcd(a: i64, b: i64) callconv(.c) i64 {
    var x = if (a < 0) -a else a;
    var y = if (b < 0) -b else b;
    while (y != 0) {
        const t = y;
        y = @mod(x, y);
        x = t;
    }
    return x;
}

pub fn ko_int_lcm(a: i64, b: i64) callconv(.c) i64 {
    if (a == 0 or b == 0) return 0;
    return (@divTrunc(a, ko_int_gcd(a, b))) * b;
}

pub fn ko_int_factorial(n: i64) callconv(.c) i64 {
    if (n < 0) return 0;
    var result: i64 = 1;
    var i: i64 = 2;
    while (i <= n) : (i += 1) {
        result *= i;
    }
    return result;
}

pub fn ko_int_isqrt(n: i64) callconv(.c) i64 {
    if (n <= 0) return 0;
    var x: i64 = n;
    var y: i64 = @divTrunc(x + 1, 2);
    while (y < x) {
        x = y;
        y = @divTrunc(x + @divTrunc(n, x), 2);
    }
    return x;
}

// ============================================================
// String operations
// ============================================================

pub fn ko_string_to_int(str: ?[*:0]const u8, out: ?*i64) callconv(.c) i64 {
    const s = str orelse return 0;
    const o = out orelse return 0;
    const val = std.fmt.parseInt(i64, std.mem.sliceTo(s, 0), 10) catch return 0;
    o.* = val;
    return 1;
}

pub fn ko_string_length(str: ?[*:0]const u8) callconv(.c) i64 {
    const s = str orelse return 0;
    var len: i64 = 0;
    while (s[@intCast(len)] != 0) {
        len += 1;
    }
    return len;
}

pub fn ko_string_append(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const sa = a orelse "";
    const sb = b orelse "";
    var len_a: usize = 0;
    while (sa[len_a] != 0) : (len_a += 1) {}
    var len_b: usize = 0;
    while (sb[len_b] != 0) : (len_b += 1) {}
    const buf = std.heap.page_allocator.alloc(u8, len_a + len_b + 1) catch return null;
    @memcpy(buf[0..len_a], sa[0..len_a]);
    @memcpy(buf[len_a..][0..len_b], sb[0..len_b]);
    buf[len_a + len_b] = 0;
    return @ptrCast(buf.ptr);
}

pub fn ko_string_eq(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) i64 {
    const sa = a orelse "";
    const sb = b orelse "";
    var i: usize = 0;
    while (sa[i] != 0 and sb[i] != 0) : (i += 1) {
        if (sa[i] != sb[i]) return 0;
    }
    return if (sa[i] == 0 and sb[i] == 0) 1 else 0;
}

pub fn ko_string_contains(haystack: ?[*:0]const u8, needle: ?[*:0]const u8) callconv(.c) i64 {
    const h = haystack orelse return 0;
    const n = needle orelse return 0;
    var i: usize = 0;
    while (h[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (n[j] != 0 and h[i + j] == n[j]) : (j += 1) {}
        if (n[j] == 0) return 1;
    }
    return 0;
}

pub fn ko_string_char_at(str: ?[*:0]const u8, index: i64) callconv(.c) i64 {
    const s = str orelse return 0;
    if (index < 0) return 0;
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    const idx: usize = @intCast(index);
    if (idx >= len) return 0;
    return @intCast(s[idx]);
}

pub fn ko_string_to_upper(str: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const s = str orelse return null;
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    const buf = std.heap.page_allocator.alloc(u8, len + 1) catch return null;
    for (0..len) |i| {
        buf[i] = std.ascii.toUpper(s[i]);
    }
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

pub fn ko_string_to_lower(str: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const s = str orelse return null;
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    const buf = std.heap.page_allocator.alloc(u8, len + 1) catch return null;
    for (0..len) |i| {
        buf[i] = std.ascii.toLower(s[i]);
    }
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

pub fn ko_string_trim(str: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const s = str orelse return null;
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    if (len == 0) {
        const buf = std.heap.page_allocator.alloc(u8, 1) catch return null;
        buf[0] = 0;
        return @ptrCast(buf.ptr);
    }
    var start: usize = 0;
    while (start < len and std.ascii.isWhitespace(s[start])) : (start += 1) {}
    var end: usize = len;
    while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}
    const new_len = end - start;
    const buf = std.heap.page_allocator.alloc(u8, new_len + 1) catch return null;
    @memcpy(buf[0..new_len], s[start..end]);
    buf[new_len] = 0;
    return @ptrCast(buf.ptr);
}

pub fn ko_string_replace(str: ?[*:0]const u8, from: ?[*:0]const u8, to: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const s = str orelse return null;
    const f = from orelse return null;
    const t = to orelse return null;
    var from_len: usize = 0;
    while (f[from_len] != 0) : (from_len += 1) {}
    if (from_len == 0) return null;
    var to_len: usize = 0;
    while (t[to_len] != 0) : (to_len += 1) {}
    var str_len: usize = 0;
    while (s[str_len] != 0) : (str_len += 1) {}
    var count: usize = 0;
    var i: usize = 0;
    while (i <= str_len -| from_len) : (i += 1) {
        var j: usize = 0;
        while (j < from_len and s[i + j] == f[j]) : (j += 1) {}
        if (j == from_len) {
            count += 1;
            i += from_len - 1;
        }
    }
    if (count == 0) return null;
    const new_len = str_len + count * (to_len -| from_len);
    const buf = std.heap.page_allocator.alloc(u8, new_len + 1) catch return null;
    var dst: usize = 0;
    var src: usize = 0;
    while (src < str_len) : (src += 1) {
        if (src <= str_len - from_len) {
            var j: usize = 0;
            while (j < from_len and s[src + j] == f[j]) : (j += 1) {}
            if (j == from_len) {
                @memcpy(buf[dst..][0..to_len], t[0..to_len]);
                dst += to_len;
                src += from_len - 1;
                continue;
            }
        }
        buf[dst] = s[src];
        dst += 1;
    }
    buf[dst] = 0;
    return @ptrCast(buf.ptr);
}

// ============================================================
// Float operations
// ============================================================

pub fn ko_float_of_int(val: i64) callconv(.c) f64 {
    return @floatFromInt(val);
}

pub fn ko_float_to_int(val: f64) callconv(.c) i64 {
    return @intFromFloat(val);
}

pub fn ko_float_sqrt(val: f64) callconv(.c) f64 {
    return @sqrt(val);
}

pub fn ko_float_pow(base: f64, exp: f64) callconv(.c) f64 {
    return std.math.pow(f64, base, exp);
}

pub fn ko_float_sin(val: f64) callconv(.c) f64 {
    return std.math.sin(val);
}

pub fn ko_float_cos(val: f64) callconv(.c) f64 {
    return std.math.cos(val);
}

pub fn ko_float_tan(val: f64) callconv(.c) f64 {
    return std.math.tan(val);
}

pub fn ko_float_log(val: f64) callconv(.c) f64 {
    return @log(val);
}

pub fn ko_float_log2(val: f64) callconv(.c) f64 {
    return std.math.log2(val);
}

pub fn ko_float_log10(val: f64) callconv(.c) f64 {
    return std.math.log10(val);
}

pub fn ko_float_exp(val: f64) callconv(.c) f64 {
    return std.math.exp(val);
}

pub fn ko_float_floor(val: f64) callconv(.c) f64 {
    return std.math.floor(val);
}

pub fn ko_float_ceil(val: f64) callconv(.c) f64 {
    return std.math.ceil(val);
}

pub fn ko_float_abs(val: f64) callconv(.c) f64 {
    return @abs(val);
}

// ============================================================
// Result operations
// ============================================================

// Result struct: { i64 tag, i64 value } — tag 0 = Ok, tag 1 = Err
const ResultTag = enum(i64) { ok = 0, err = 1 };

fn resultTag(ptr: i64) ResultTag {
    const p: *[2]i64 = @ptrFromInt(@as(usize, @intCast(ptr)));
    return @enumFromInt(p[0]);
}

fn resultValue(ptr: i64) i64 {
    const p: *[2]i64 = @ptrFromInt(@as(usize, @intCast(ptr)));
    return p[1];
}

fn setResultTag(ptr: i64, tag: ResultTag) void {
    const p: *[2]i64 = @ptrFromInt(@as(usize, @intCast(ptr)));
    p[0] = @intFromEnum(tag);
}

fn setResultValue(ptr: i64, val: i64) void {
    const p: *[2]i64 = @ptrFromInt(@as(usize, @intCast(ptr)));
    p[1] = val;
}

pub fn ko_result_is_ok(result: i64) callconv(.c) i64 {
    return if (resultTag(result) == .ok) 1 else 0;
}

pub fn ko_result_is_err(result: i64) callconv(.c) i64 {
    return if (resultTag(result) == .err) 1 else 0;
}

pub fn ko_result_unwrap(default: i64, result: i64) callconv(.c) i64 {
    return if (resultTag(result) == .ok) resultValue(result) else default;
}

// ko_result_unwrap_or: Return Ok value, or default if Err (non-panicking)
pub fn ko_result_unwrap_or(default: i64, result: i64) callconv(.c) i64 {
    return if (resultTag(result) == .ok) resultValue(result) else default;
}

// ko_panic: Panic with a message and abort
pub fn ko_panic(msg_ptr: [*]const u8, msg_len: i64) callconv(.c) void {
    const fdio = @import("fdio.zig");
    const prefix = "ko: panic: ";
    _ = fdio.write(fdio.stderr, prefix);
    _ = fdio.write(fdio.stderr, msg_ptr[0..@intCast(msg_len)]);
    _ = fdio.write(fdio.stderr, "\n");
    std.c.abort();
}

// ko_panic_str: Panic with a message (null-terminated ptr) and abort
pub fn ko_panic_str(msg_ptr: [*:0]const u8) callconv(.c) void {
    const len: i64 = @intCast(std.mem.len(msg_ptr));
    ko_panic(msg_ptr, len);
}

// ko_assert: Panic if the bool is false, with custom message
pub fn ko_assert(val: i64, msg_ptr: [*:0]const u8) callconv(.c) void {
    if (val == 0) {
        const len: i64 = @intCast(std.mem.len(msg_ptr));
        ko_panic(msg_ptr, len);
    }
}

// ko_assert_eq: Panic if two values are not equal, with custom message
pub fn ko_assert_eq(a: i64, b: i64, msg_ptr: [*:0]const u8) callconv(.c) void {
    if (a != b) {
        const len: i64 = @intCast(std.mem.len(msg_ptr));
        ko_panic(msg_ptr, len);
    }
}

// ko_result_unwrap_panic: Return Ok value, or panic if Err
pub fn ko_result_unwrap_panic(result: i64) callconv(.c) i64 {
    if (resultTag(result) == .ok) return resultValue(result);
    const msg = "unwrap: Err value";
    ko_panic(msg.ptr, @intCast(msg.len));
    unreachable;
}

pub fn ko_result_tag(result: i64) callconv(.c) i64 {
    return @intFromEnum(resultTag(result));
}

pub fn ko_result_value(result: i64) callconv(.c) i64 {
    return resultValue(result);
}

// ko_result_map(fn_val, result): apply fn to Ok value, return new Result
// fn_val uses Kō calling convention: bit 0 = closure tag
pub fn ko_result_map(fn_val: i64, result: i64) callconv(.c) i64 {
    if (resultTag(result) == .err) return result;
    const val = resultValue(result);

    // Call fn_val with val using Kō calling convention
    const fn_ptr_int: usize = @intCast(fn_val);
    const is_closure: bool = (fn_ptr_int & 1) != 0;

    const raw_result: i64 = if (is_closure) blk: {
        // Closure: bit 0 set. Load fn_ptr from closure struct, call with closure as first arg
        const closure_ptr: usize = fn_ptr_int & ~@as(usize, 1);
        const closure_mem: *const [3]i64 = @ptrFromInt(closure_ptr);
        const actual_fn_ptr: *const fn (i64, i64) callconv(.c) i64 = @ptrFromInt(@as(usize, @intCast(closure_mem[0])));
        break :blk actual_fn_ptr(@intCast(closure_ptr), val);
    } else blk: {
        // Raw function pointer
        const actual_fn_ptr: *const fn (i64) callconv(.c) i64 = @ptrFromInt(fn_ptr_int);
        break :blk actual_fn_ptr(val);
    };

    // Wrap result in Ok: allocate new {0, raw_result}
    return ko_alloc_result(0, raw_result);
}

// ko_alloc_result(tag, value): allocate a Result struct on the heap
fn ko_alloc_result(tag: i64, value: i64) i64 {
    // Use raw malloc for now (TODO: integrate with ko_alloc)
    const p: *[2]i64 = @ptrCast(@alignCast(std.heap.page_allocator.alloc(i64, 2) catch return 0));
    p[0] = tag;
    p[1] = value;
    return @bitCast(@as(usize, @intFromPtr(p)));
}

// ko_result_fold(ok_fn, err_fn, result): apply ok_fn to Ok value or err_fn to Err value
pub fn ko_result_fold(ok_fn: i64, err_fn: i64, result: i64) callconv(.c) i64 {
    if (resultTag(result) == .ok) {
        return call_ko_fn_1(ok_fn, resultValue(result));
    } else {
        return call_ko_fn_1(err_fn, resultValue(result));
    }
}

// ko_result_and_then(fn_val, result): if Ok, apply fn to value (fn returns Result)
pub fn ko_result_and_then(fn_val: i64, result: i64) callconv(.c) i64 {
    if (resultTag(result) == .err) return result;
    return call_ko_fn_1(fn_val, resultValue(result));
}

// Helper: call a Kō function with 1 argument using Kō calling convention
fn call_ko_fn_1(fn_val: i64, arg: i64) i64 {
    const fn_ptr_int: usize = @intCast(fn_val);
    const is_closure: bool = (fn_ptr_int & 1) != 0;

    if (is_closure) {
        const closure_ptr: usize = fn_ptr_int & ~@as(usize, 1);
        const closure_mem: *const [3]i64 = @ptrFromInt(closure_ptr);
        const actual_fn_ptr: *const fn (i64, i64) callconv(.c) i64 = @ptrFromInt(@as(usize, @intCast(closure_mem[0])));
        return actual_fn_ptr(@intCast(closure_ptr), arg);
    } else {
        const actual_fn_ptr: *const fn (i64) callconv(.c) i64 = @ptrFromInt(fn_ptr_int);
        return actual_fn_ptr(arg);
    }
}

// ko_string_split(str, delimiter) -> List String (heap-allocated Cons/Nil)
// Returns a list of substrings split by the delimiter.
pub fn ko_string_split(str: ?[*:0]const u8, delimiter: ?[*:0]const u8) callconv(.c) i64 {
    const s = str orelse return 1; // Nil
    const d = delimiter orelse return 1; // Nil

    var delim_len: usize = 0;
    while (d[delim_len] != 0) : (delim_len += 1) {}
    if (delim_len == 0) return 1; // Nil

    var str_len: usize = 0;
    while (s[str_len] != 0) : (str_len += 1) {}

    // Count segments
    var count: usize = 1;
    var i: usize = 0;
    while (i <= str_len -| delim_len) : (i += 1) {
        var j: usize = 0;
        while (j < delim_len and s[i + j] == d[j]) : (j += 1) {}
        if (j == delim_len) {
            count += 1;
            i += delim_len - 1;
        }
    }

    // Build list from right to left (so order is correct after reversal)
    var result: i64 = 1; // start with Nil
    var start: usize = 0;
    i = 0;
    while (i <= str_len) : (i += 1) {
        var matched = false;
        if (i <= str_len - delim_len) {
            var j: usize = 0;
            while (j < delim_len and s[i + j] == d[j]) : (j += 1) {}
            matched = (j == delim_len);
        }
        if (matched or i == str_len) {
            const seg_len = i - start;
            // Allocate and copy substring
            const buf = std.heap.page_allocator.alloc(u8, seg_len + 1) catch return result;
            var k: usize = 0;
            while (k < seg_len) : (k += 1) {
                buf[k] = s[start + k];
            }
            buf[seg_len] = 0;
            const str_ptr: i64 = @bitCast(@as(usize, @intFromPtr(buf.ptr)));
            // Cons(str_ptr, result) — allocate 3-i64 struct: [tag=0, head, tail]
            const cons_struct: *[3]i64 = @ptrCast(std.heap.page_allocator.alloc(i64, 3) catch return result);
            cons_struct[0] = 0; // Cons tag
            cons_struct[1] = str_ptr;
            cons_struct[2] = result;
            result = @bitCast(@as(usize, @intFromPtr(cons_struct)));
            start = i + delim_len;
            i = start - 1; // will be incremented by loop
        }
    }

    // Reverse the list
    var reversed: i64 = 1; // Nil
    var current = result;
    while (current != 1) { // not Nil
        const ptr: usize = @bitCast(current);
        const node: *const [3]i64 = @ptrFromInt(ptr);
        const head_val = node[1];
        const tail_val = node[2];
        const new_node: *[3]i64 = @ptrCast(std.heap.page_allocator.alloc(i64, 3) catch break);
        new_node[0] = 0; // Cons tag
        new_node[1] = head_val;
        new_node[2] = reversed;
        reversed = @bitCast(@as(usize, @intFromPtr(new_node)));
        current = tail_val;
    }
    return reversed;
}

// ============================================================
// IO builtins (Stage 5)
//
// File/console/environment builtins implemented as native host
// functions and mapped into the JIT (see main.zig). String
// arguments arrive as KoString data pointers (NUL-terminated); a
// null pointer is treated as an empty string.
//
// Result/Maybe values are boxed with the ko_alloc layout: a
// 32-byte header behind the data pointer (rc=1, type_tag=1,
// arity=0, bitmap=0) and [tag, payload] in the data area.
// Result tags: Ok=0, Err=1. Error tags (positional, must match
// typecheck.zig registerPrelude and lir_lower.zig registerBuiltins):
// FileNotFound=0, PermissionDenied=1, InvalidPath=2, IOError=3,
// EncodingError=4. Zero-param Error constructors are small ints.
//
// The bitmap is left 0, so decref frees the box without recursing
// into payloads; heap payloads may leak. This matches how the
// runtime treats boxes built from `Ok`/`Err` applications. Boxes
// and strings are allocated with libc malloc so ko_decref's free
// (which frees data - 32) matches.
//
// POSIX libc only: building on Windows would need CRT shims.
// ============================================================

const ERR_FILENOTFOUND: i64 = 0;
const ERR_PERMISSION: i64 = 1;
const ERR_INVALIDPATH: i64 = 2;
const ERR_IOERROR: i64 = 3;

// Array type tags, matching stdlib_codegen.zig: 11 = scalar
// elements, 12 = heap elements.
const array_tag_heap: i64 = 12;

extern "c" fn close(fd: c_int) c_int;
extern "c" fn lseek(fd: c_int, offset: c_long, whence: c_int) c_long;
extern "c" fn readdir(dir: *std.c.DIR) ?*std.c.dirent;

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

/// Convert a pointer to the i64 universal representation.
fn ptr_i64(p: anytype) i64 {
    return @bitCast(@as(usize, @intFromPtr(p)));
}

/// Wrap a byte slice in a KoString box. Returns the data pointer
/// (the value passed around), or null on OOM.
fn ko_string_box(data: []const u8) ?[*:0]const u8 {
    const raw = std.c.malloc(32 + data.len + 1) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    const hdr: *[4]i64 = @ptrCast(@alignCast(base));
    hdr[0] = 1; // refcount (managed)
    hdr[1] = 4; // type_tag = string
    hdr[2] = @intCast(data.len);
    hdr[3] = 0; // bitmap
    @memcpy(base[32 .. 32 + data.len], data);
    base[32 + data.len] = 0;
    return @ptrCast(base + 32);
}

/// Build a 2-slot constructor box ([tag, payload]) with the
/// ko_alloc header layout. Returns the data pointer as an i64,
/// or 0 on OOM.
fn ko_box2(tag: i64, payload: i64) i64 {
    const raw = std.c.malloc(32 + 16) orelse return 0;
    const base: [*]u8 = @ptrCast(raw);
    const hdr: *[4]i64 = @ptrCast(@alignCast(base));
    hdr[0] = 1; // refcount
    hdr[1] = 1; // type_tag = constructor
    hdr[2] = 0; // arity
    hdr[3] = 0; // bitmap
    const user: *[2]i64 = @ptrCast(@alignCast(base + 32));
    user[0] = tag;
    user[1] = payload;
    return @bitCast(@as(usize, @intFromPtr(user)));
}

fn ko_ok(v: i64) i64 {
    return ko_box2(0, v);
}

/// Err with a zero-param Error constructor (small-int payload).
fn ko_err(tag: i64) i64 {
    return ko_box2(1, tag);
}

/// Err (IOError msg), where msg is boxed as a KoString.
fn ko_err_ioerror(msg: []const u8) i64 {
    const s = ko_string_box(msg) orelse return ko_err(ERR_IOERROR);
    const inner = ko_box2(ERR_IOERROR, ptr_i64(s));
    return ko_box2(1, inner);
}

fn ko_err_from(e: std.c.E) i64 {
    return switch (e) {
        .NOENT => ko_err(ERR_FILENOTFOUND),
        .ACCES, .PERM => ko_err(ERR_PERMISSION),
        .INVAL, .NAMETOOLONG, .LOOP => ko_err(ERR_INVALIDPATH),
        else => blk: {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "errno {d}", .{@intFromEnum(e)}) catch "errno";
            break :blk ko_err_ioerror(msg);
        },
    };
}

/// IO.readFile : String -> Result Error String
pub fn ko_io_read_file(path: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return ko_err_from(std.c.errno(fd));
    defer _ = close(fd);

    // Sizing via lseek avoids needing a portable `stat`; regular files only.
    const size = lseek(fd, 0, SEEK_END);
    if (size < 0) return ko_err_from(std.c.errno(-1));
    _ = lseek(fd, 0, SEEK_SET);

    const raw = std.c.malloc(32 + @as(usize, @intCast(size)) + 1) orelse return ko_err_ioerror("out of memory");
    const base: [*]u8 = @ptrCast(raw);
    const hdr: *[4]i64 = @ptrCast(@alignCast(base));
    hdr[0] = 1;
    hdr[1] = 4;
    hdr[2] = size;
    hdr[3] = 0;
    const data = base[32 .. 32 + @as(usize, @intCast(size))];
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.read(fd, data[off..].ptr, data.len - off);
        if (n < 0) {
            std.c.free(raw);
            return ko_err_from(std.c.errno(n));
        }
        if (n == 0) break;
        off += @intCast(n);
    }
    base[32 + off] = 0;
    hdr[2] = @intCast(off);
    return ko_ok(ptr_i64(base + 32));
}

/// Write a byte buffer to an already-open file descriptor, returning
/// true on success.
fn write_all(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n < 0) return false;
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// IO.writeFile : String -> String -> Result Error Unit
pub fn ko_io_write_file(path: ?[*:0]const u8, contents: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    const c = contents orelse "";
    const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return ko_err_from(std.c.errno(fd));
    defer _ = close(fd);
    if (!write_all(fd, std.mem.sliceTo(c, 0))) return ko_err_from(std.c.errno(-1));
    return ko_ok(0);
}

/// IO.appendFile : String -> String -> Result Error Unit
pub fn ko_io_append_file(path: ?[*:0]const u8, contents: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    const c = contents orelse "";
    const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return ko_err_from(std.c.errno(fd));
    defer _ = close(fd);
    if (!write_all(fd, std.mem.sliceTo(c, 0))) return ko_err_from(std.c.errno(-1));
    return ko_ok(0);
}

/// IO.fileExists : String -> Bool
pub fn ko_io_file_exists(path: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    // F_OK = 0. Returns 0 on success, -1 (with errno) when missing.
    return @intFromBool(std.c.access(p, 0) == 0);
}

/// IO.fileSize : String -> Result Error Int
pub fn ko_io_file_size(path: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return ko_err_from(std.c.errno(fd));
    defer _ = close(fd);
    const size = lseek(fd, 0, SEEK_END);
    if (size < 0) return ko_err_from(std.c.errno(-1));
    return ko_ok(size);
}

/// IO.mkdir : String -> Result Error Unit
pub fn ko_io_mkdir(path: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    if (std.c.mkdir(p, 0o755) != 0) return ko_err_from(std.c.errno(-1));
    return ko_ok(0);
}

/// IO.rm : String -> Result Error Unit. Removes a file or empty directory.
pub fn ko_io_rm(path: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    if (std.c.unlink(p) != 0) {
        if (std.c.rmdir(p) != 0) return ko_err_from(std.c.errno(-1));
    }
    return ko_ok(0);
}

/// IO.cp : String -> String -> Result Error Unit
pub fn ko_io_cp(src: ?[*:0]const u8, dst: ?[*:0]const u8) callconv(.c) i64 {
    const s = src orelse "";
    const d = dst orelse "";
    const in_fd = std.c.open(s, .{ .ACCMODE = .RDONLY });
    if (in_fd < 0) return ko_err_from(std.c.errno(in_fd));
    defer _ = close(in_fd);

    const out_fd = std.c.open(d, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (out_fd < 0) return ko_err_from(std.c.errno(out_fd));
    defer _ = close(out_fd);

    while (true) {
        var chunk: [8192]u8 = undefined;
        const n = std.c.read(in_fd, &chunk, chunk.len);
        if (n < 0) return ko_err_from(std.c.errno(n));
        if (n == 0) break;
        if (!write_all(out_fd, chunk[0..@intCast(n)])) return ko_err_from(std.c.errno(-1));
    }
    return ko_ok(0);
}

/// IO.mv : String -> String -> Result Error Unit
pub fn ko_io_mv(src: ?[*:0]const u8, dst: ?[*:0]const u8) callconv(.c) i64 {
    const s = src orelse "";
    const d = dst orelse "";
    if (std.c.rename(s, d) != 0) return ko_err_from(std.c.errno(-1));
    return ko_ok(0);
}

/// IO.readdir : String -> Result Error (Array String)
pub fn ko_io_readdir(path: ?[*:0]const u8) callconv(.c) i64 {
    const p = path orelse "";
    const dir = std.c.opendir(p) orelse return ko_err_from(std.c.errno(-1));
    defer _ = std.c.closedir(dir);

    var items: std.ArrayList(?[*:0]const u8) = .empty;
    while (readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const boxed = ko_string_box(name) orelse continue;
        items.append(std.heap.page_allocator, @ptrCast(boxed)) catch continue;
    }

    const n = items.items.len;
    const raw = std.c.malloc(32 + n * 8) orelse {
        items.deinit(std.heap.page_allocator);
        return ko_err_ioerror("out of memory");
    };
    const base: [*]u8 = @ptrCast(raw);
    const hdr: *[4]i64 = @ptrCast(@alignCast(base));
    hdr[0] = 1; // refcount
    hdr[1] = array_tag_heap;
    hdr[2] = @intCast(n); // length
    hdr[3] = @intCast(n); // capacity
    const elems: [*]i64 = @ptrCast(@alignCast(base + 32));
    for (items.items, 0..) |it, i| {
        elems[i] = ptr_i64(it);
    }
    items.deinit(std.heap.page_allocator);
    return ko_ok(ptr_i64(base + 32));
}

/// IO.readLine : String -> String. Prints the prompt to stdout, then
/// reads one line (without the trailing newline) from stdin.
pub fn ko_io_read_line(prompt: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const fdio = @import("fdio.zig");
    const pr = prompt orelse "";
    _ = fdio.write(fdio.stdout, std.mem.sliceTo(pr, 0));

    var buf: std.ArrayList(u8) = .empty;
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &byte, 1);
        if (n <= 0) break;
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        buf.append(std.heap.page_allocator, byte[0]) catch break;
    }
    const boxed = ko_string_box(buf.items) orelse {
        buf.deinit(std.heap.page_allocator);
        return null;
    };
    buf.deinit(std.heap.page_allocator);
    return boxed;
}

/// IO.eprintln : String -> Unit
pub fn ko_io_eprintln(msg: ?[*:0]const u8) callconv(.c) i64 {
    const fdio = @import("fdio.zig");
    const m = msg orelse "";
    _ = fdio.write(fdio.stderr, std.mem.sliceTo(m, 0));
    _ = fdio.write(fdio.stderr, "\n");
    return 0;
}

/// IO.eprint : String -> Unit
pub fn ko_io_eprint(msg: ?[*:0]const u8) callconv(.c) i64 {
    const fdio = @import("fdio.zig");
    const m = msg orelse "";
    _ = fdio.write(fdio.stderr, std.mem.sliceTo(m, 0));
    return 0;
}

/// IO.getEnv : String -> Maybe String
pub fn ko_io_get_env(name: ?[*:0]const u8) callconv(.c) i64 {
    const n = name orelse "";
    const raw = std.c.getenv(n) orelse return 1; // Nothing
    const boxed = ko_string_box(std.mem.sliceTo(raw, 0)) orelse return 1;
    return ko_box2(0, ptr_i64(boxed)); // Just str
}
