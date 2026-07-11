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
