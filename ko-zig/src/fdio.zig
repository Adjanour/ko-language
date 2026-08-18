//! Portable raw file-descriptor I/O.
//!
//! The compiler and LSP use fd 0/1/2 for stdin/stdout/stderr and open/read
//! files via fds. `std.c.fd_t` is `*anyopaque` (HANDLE) on Windows, so
//! `std.c.write(2, ...)` does not compile there. The CRT functions
//! `_write`/`_read`/`_close`/`_open` take small integer fds on every target
//! (msvcrt/mingw on Windows, libc elsewhere), so this shim dispatches on the
//! target and only references the underscored names on Windows.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

pub const fd_t = c_int;

pub const stdin: fd_t = 0;
pub const stdout: fd_t = 1;
pub const stderr: fd_t = 2;

pub fn write(fd: fd_t, buf: []const u8) isize {
    if (comptime is_windows) return _write(fd, buf.ptr, buf.len);
    return std.c.write(fd, buf.ptr, buf.len);
}

pub fn read(fd: fd_t, buf: []u8) isize {
    if (comptime is_windows) return _read(fd, buf.ptr, buf.len);
    return std.c.read(fd, buf.ptr, buf.len);
}

pub fn close(fd: fd_t) void {
    if (comptime is_windows) {
        _ = _close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub fn open(path: []const u8) isize {
    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch return -1;
    defer std.heap.c_allocator.free(path_z);
    if (comptime is_windows) return _open(path_z.ptr, 0); // _O_RDONLY
    return std.c.open(path_z.ptr, .{}); // O_RDONLY (no flags)
}

extern "c" fn _write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn _read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
extern "c" fn _close(fd: c_int) c_int;
extern "c" fn _open(path: [*:0]const u8, flags: c_int) c_int;