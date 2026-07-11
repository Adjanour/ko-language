const std = @import("std");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");

pub const LoadedModule = struct {
    program: parser.Program,
    source: [:0]const u8,
    file_path: []const u8,
};

pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    /// Cache of loaded modules: file_path -> LoadedModule
    cache: std.StringHashMap(*LoadedModule),
    /// Source directory of the file being compiled
    base_dir: []const u8,
    /// Optional stdlib override from KO_STDLIB_PATH.
    stdlib_override: ?[]const u8,
    /// Directory containing the executable, used to search for stdlib next to the binary.
    exe_dir: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        stdlib_override: ?[]const u8,
        exe_dir: ?[]const u8,
    ) ModuleLoader {
        return .{
            .allocator = allocator,
            .cache = std.StringHashMap(*LoadedModule).init(allocator),
            .base_dir = base_dir,
            .stdlib_override = stdlib_override,
            .exe_dir = exe_dir,
        };
    }

    pub fn deinit(self: *ModuleLoader) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.source);
            self.allocator.free(entry.value_ptr.*.file_path);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.deinit();
        if (self.exe_dir) |path| {
            self.allocator.free(path);
        }
    }

    /// Resolve an import path (e.g., ["std", "math"]) to a file path (e.g., "std/math.ko")
    pub fn resolvePath(self: *ModuleLoader, import_path: []const []const u8) ![]const u8 {
        // Join with "/" and append ".ko"
        var parts = std.ArrayList(u8).empty;
        defer parts.deinit(self.allocator);

        // Add base dir if present
        if (self.base_dir.len > 0) {
            try parts.appendSlice(self.allocator, self.base_dir);
            // Ensure trailing slash
            if (self.base_dir[self.base_dir.len - 1] != '/') {
                try parts.append(self.allocator, '/');
            }
        }

        for (import_path, 0..) |part, i| {
            try parts.appendSlice(self.allocator, part);
            if (i < import_path.len - 1) {
                try parts.append(self.allocator, '/');
            }
        }
        try parts.appendSlice(self.allocator, ".ko");

        return try self.allocator.dupe(u8, parts.items);
    }

    /// Build a stdlib path from stdlib_base and import_path (e.g., /path/to/std + [List] -> /path/to/std/List.ko)
    fn buildStdlibPath(self: *ModuleLoader, stdlib_base: []const u8, import_path: []const []const u8) ![]const u8 {
        var parts = std.ArrayList(u8).empty;
        defer parts.deinit(self.allocator);

        try parts.appendSlice(self.allocator, stdlib_base);
        if (stdlib_base.len > 0 and stdlib_base[stdlib_base.len - 1] != '/') {
            try parts.append(self.allocator, '/');
        }

        for (import_path, 0..) |part, i| {
            try parts.appendSlice(self.allocator, part);
            if (i < import_path.len - 1) {
                try parts.append(self.allocator, '/');
            }
        }
        try parts.appendSlice(self.allocator, ".ko");

        return try self.allocator.dupe(u8, parts.items);
    }

    fn stdlibImportPath(import_path: []const []const u8) []const []const u8 {
        if (import_path.len >= 2 and std.mem.eql(u8, import_path[0], "std")) {
            return import_path[1..];
        }
        return import_path;
    }

    /// Load and parse a module. Searches in base_dir first, then an explicit stdlib root,
    /// then executable-relative stdlib paths.
    pub fn loadModule(self: *ModuleLoader, import_path: []const []const u8) !?*LoadedModule {
        const file_path = try self.resolvePath(import_path);
        defer self.allocator.free(file_path);

        // Check cache
        if (self.cache.get(file_path)) |cached| {
            return cached;
        }

        // Try to read from base_dir first
        const source = self.readFile(file_path) catch |err| {
            if (err != error.FileNotFound) return err;

            return try self.loadStdlibModule(file_path, import_path);
        };

        // Parse the source loaded from base_dir
        var p = try parser.Parser.init(self.allocator, source);
        defer p.deinit();
        const program = try p.parse_program();

        // Cache
        const mod = try self.allocator.create(LoadedModule);
        mod.* = .{
            .program = program,
            .source = source,
            .file_path = try self.allocator.dupe(u8, file_path),
        };
        try self.cache.put(try self.allocator.dupe(u8, file_path), mod);

        return mod;
    }

    fn loadStdlibModule(self: *ModuleLoader, cache_key: []const u8, import_path: []const []const u8) !?*LoadedModule {
        const stdlib_import_path = stdlibImportPath(import_path);
        if (stdlib_import_path.len == 0) return null;

        const candidate_roots = [_]?[]const u8{
            self.stdlib_override,
            self.exe_dir,
        };

        const candidate_suffixes = [_][]const u8{
            "std",
            "../std",
            "../../std",
        };

        for (candidate_roots) |candidate_root_opt| {
            const candidate_root = candidate_root_opt orelse continue;
            for (candidate_suffixes) |relative_stdlib_dir| {
                const stdlib_root = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ candidate_root, relative_stdlib_dir });
                defer self.allocator.free(stdlib_root);

                const stdlib_file_path = try self.buildStdlibPath(stdlib_root, stdlib_import_path);
                defer self.allocator.free(stdlib_file_path);

                if (try self.loadModuleFromPath(stdlib_file_path, cache_key, import_path)) |mod| {
                    return mod;
                }
            }
        }

        return null;
    }

    /// Helper to load a module from a specific file path
    fn loadModuleFromPath(self: *ModuleLoader, stdlib_file_path: []const u8, cache_key: []const u8, _: []const []const u8) !?*LoadedModule {
        const source = self.readFile(stdlib_file_path) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };

        var p = try parser.Parser.init(self.allocator, source);
        defer p.deinit();
        const program = try p.parse_program();

        // Cache
        const mod = try self.allocator.create(LoadedModule);
        mod.* = .{
            .program = program,
            .source = source,
            .file_path = try self.allocator.dupe(u8, cache_key),
        };
        try self.cache.put(try self.allocator.dupe(u8, cache_key), mod);

        return mod;
    }

    fn readFile(self: *ModuleLoader, path: []const u8) anyerror![:0]const u8 {
        const fd = openFile(path) catch return error.FileNotFound;
        defer closeFd(fd);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = readFd(fd, &tmp) catch break;
            if (n == 0) break;
            try buf.appendSlice(self.allocator, tmp[0..n]);
        }

        // Create null-terminated copy (dupeZ adds the sentinel)
        return try self.allocator.dupeZ(u8, buf.items);
    }
};

// Cross-platform file I/O helpers
const posix = std.posix;

fn openFile(path: []const u8) !posix.fd_t {
    return try posix.openat(posix.AT.FDCWD, path, .{}, 0);
}

fn closeFd(fd: posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

fn readFd(fd: posix.fd_t, buf: []u8) !usize {
    return try posix.read(fd, buf);
}
