const std = @import("std");
const Io = std.Io;
const compat = @import("compat.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const comptime_boundary = @import("comptime_boundary.zig");
const compiler_cache = @import("compiler_cache.zig");

/// Logical identity for a module in one compilation workspace. `file_path` on
/// LoadedModule supplies the normalized source path portion of the identity.
pub const ModuleId = struct {
    package: []const u8,
    logical_path: []const u8,
    language_version: u32 = 1,
};

pub const LoadedModule = struct {
    id: ModuleId,
    program: parser.Program,
    source: [:0]const u8,
    file_path: []const u8,
    state: State = .parsed,
    resolution_state: ResolutionState = .unseen,
    cached_interface: ?CachedInterface = null,

    pub const State = enum {
        parsed,
        typechecking,
        failed,
    };

    pub const ResolutionState = enum {
        unseen,
        resolving,
        resolved,
        failed,
    };
};

pub const CachedInterface = struct {
    hash: u64,
    payload: []u8,
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
    interface_cache: ?*compiler_cache.Cache = null,
    interface_io: ?Io = null,
    interface_configuration: ?comptime_boundary.BuildConfiguration = null,

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
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.id.package);
            self.allocator.free(entry.value_ptr.*.id.logical_path);
            self.allocator.free(entry.value_ptr.*.source);
            self.allocator.free(entry.value_ptr.*.file_path);
            if (entry.value_ptr.*.cached_interface) |cached_interface| self.allocator.free(cached_interface.payload);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cache.deinit();
        if (self.exe_dir) |path| {
            self.allocator.free(path);
        }
    }

    pub fn configureInterfaceCache(self: *ModuleLoader, io: Io, cache: *compiler_cache.Cache, configuration: comptime_boundary.BuildConfiguration) void {
        self.interface_io = io;
        self.interface_cache = cache;
        self.interface_configuration = configuration;
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

    /// Load and parse a module.
    /// - `std.*` imports resolve from the compiler binary's directory (not the source file).
    /// - All other imports resolve from the source file's directory.
    pub fn loadModule(self: *ModuleLoader, import_path: []const []const u8) !?*LoadedModule {
        const is_std = import_path.len >= 1 and std.mem.eql(u8, import_path[0], "std");

        // For std imports: skip base_dir, go straight to stdlib resolution
        if (is_std) {
            return try self.loadStdlibFromExe(import_path);
        }

        // For non-std imports: resolve from source file's directory
        const file_path = try self.resolvePath(import_path);
        defer self.allocator.free(file_path);

        return try self.loadModuleFromPath(file_path, import_path);
    }

    /// Marks a module as actively being typechecked. Re-entering an active
    /// module is an import cycle; callers must stop before recursive inference.
    pub fn beginTypechecking(_: *ModuleLoader, mod: *LoadedModule) !void {
        switch (mod.state) {
            .parsed => mod.state = .typechecking,
            .typechecking => return error.ImportCycle,
            .failed => return error.ImportFailed,
        }
    }

    /// Completes a typechecking attempt. Successful modules return to the
    /// parsed state for now because interfaces are not cached yet. A later
    /// resolver/interface phase will replace this with a reusable typed state.
    pub fn finishTypechecking(_: *ModuleLoader, mod: *LoadedModule, succeeded: bool) void {
        mod.state = if (succeeded) .parsed else .failed;
    }

    /// Resolves every transitive import before typechecking begins. This is the
    /// first module-graph phase: later work will attach scopes and interfaces
    /// to the resolved nodes.
    pub fn resolveImportGraph(self: *ModuleLoader, imports: []const parser.Import) !void {
        for (imports) |imp| {
            const mod = try self.loadModule(imp.path) orelse return error.ModuleNotFound;
            try self.resolveModuleImports(mod);
        }
    }

    /// Stable dependency fingerprint for the resolved graph. The current
    /// loader retains source text for imported modules, so this hashes module
    /// identity plus source; typed interface hashes can replace the source
    /// component once imported interfaces are retained.
    pub fn dependencyFingerprint(self: *ModuleLoader) u64 {
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(self.allocator);
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            parts.append(self.allocator, entry.value_ptr.*.file_path) catch return 0;
            parts.append(self.allocator, entry.value_ptr.*.source) catch return 0;
        }
        return comptime_boundary.fingerprint(parts.items);
    }

    fn resolveModuleImports(self: *ModuleLoader, mod: *LoadedModule) !void {
        switch (mod.resolution_state) {
            .resolved => return,
            .resolving => return error.ImportCycle,
            .failed => return error.ImportFailed,
            .unseen => mod.resolution_state = .resolving,
        }

        for (mod.program.imports) |imp| {
            const dependency = self.loadModule(imp.path) catch |err| {
                mod.resolution_state = .failed;
                return err;
            } orelse {
                mod.resolution_state = .failed;
                return error.ModuleNotFound;
            };
            self.resolveModuleImports(dependency) catch |err| {
                mod.resolution_state = .failed;
                return err;
            };
        }

        mod.resolution_state = .resolved;
    }

    /// Load a std module from the compiler binary's directory.
    fn loadStdlibFromExe(self: *ModuleLoader, import_path: []const []const u8) !?*LoadedModule {
        // Strip "std" prefix: std.Math -> Math
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

                if (try self.loadModuleFromPath(stdlib_file_path, import_path)) |mod| {
                    return mod;
                }
            }
        }

        return null;
    }

    /// Load a module from one resolved file path. The cache uses a normalized
    /// path so lexical aliases of the same source file share one module.
    fn loadModuleFromPath(self: *ModuleLoader, file_path: []const u8, import_path: []const []const u8) !?*LoadedModule {
        const source = self.readFile(file_path) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };

        const normalized_path = try std.fs.path.resolveAlloc(self.allocator, &.{file_path});
        errdefer self.allocator.free(normalized_path);

        if (self.cache.get(normalized_path)) |cached| {
            self.allocator.free(source);
            return cached;
        }

        var p = try parser.Parser.init(self.allocator, source);
        defer p.deinit();
        const program = try p.parse_program();

        // Cache
        const mod = try self.allocator.create(LoadedModule);
        mod.* = .{
            .id = try self.makeModuleId(import_path),
            .program = program,
            .source = source,
            .file_path = normalized_path,
        };
        if (self.interface_cache) |store| if (self.interface_io) |io| if (self.interface_configuration) |configuration| {
            const key = comptime_boundary.cacheKey(.interface, .{
                .compiler_build = configuration.compiler_build,
                .language_version = configuration.language_version,
                .target = configuration.target,
                .flags = configuration.flags,
                .module_id = normalized_path,
                .source_hash = comptime_boundary.fingerprint(&.{source}),
                .interface_hash = 0,
                .dependency_hash = 0,
                .stdlib_hash = 0,
                .comptime_input_hash = 0,
                .representation_version = configuration.representation_version,
                .llvm_version = configuration.llvm_version,
            });
            if (store.get(io, Io.Dir.cwd(), .interface, key) catch null) |payload| {
                mod.cached_interface = .{ .hash = comptime_boundary.fingerprint(&.{payload}), .payload = payload };
            }
        };
        try self.cache.put(try self.allocator.dupe(u8, normalized_path), mod);

        return mod;
    }

    fn makeModuleId(self: *ModuleLoader, import_path: []const []const u8) !ModuleId {
        const package = if (import_path.len > 0 and std.mem.eql(u8, import_path[0], "std")) "std" else "workspace";
        const logical_path = try std.mem.join(self.allocator, ".", import_path);
        return .{
            .package = try self.allocator.dupe(u8, package),
            .logical_path = logical_path,
        };
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
        return try compat.dupeZ(self.allocator, buf.items);
    }
};

// Cross-platform file I/O helpers (fdio uses integer CRT fds on all targets)
const fdio = @import("fdio.zig");

fn openFile(path: []const u8) !fdio.fd_t {
    const fd = fdio.open(path);
    if (fd < 0) return error.FileNotFound;
    return @intCast(fd);
}

test "module loader rejects active typechecking cycles" {
    var loader = ModuleLoader.init(std.testing.allocator, ".", null, null);
    defer loader.deinit();

    var mod = LoadedModule{
        .id = .{ .package = "workspace", .logical_path = "example" },
        .program = .{ .imports = &.{}, .definitions = &.{}, .package = null },
        .source = "",
        .file_path = "example.ko",
    };

    try loader.beginTypechecking(&mod);
    try std.testing.expectError(error.ImportCycle, loader.beginTypechecking(&mod));
    loader.finishTypechecking(&mod, true);
    try std.testing.expectEqual(LoadedModule.State.parsed, mod.state);
}

test "module loader assigns package and logical identities" {
    var loader = ModuleLoader.init(std.testing.allocator, ".", null, null);
    defer loader.deinit();

    const workspace_id = try loader.makeModuleId(&.{ "app", "Json" });
    defer loader.allocator.free(workspace_id.package);
    defer loader.allocator.free(workspace_id.logical_path);
    try std.testing.expectEqualStrings("workspace", workspace_id.package);
    try std.testing.expectEqualStrings("app.Json", workspace_id.logical_path);

    const std_id = try loader.makeModuleId(&.{ "std", "List" });
    defer loader.allocator.free(std_id.package);
    defer loader.allocator.free(std_id.logical_path);
    try std.testing.expectEqualStrings("std", std_id.package);
    try std.testing.expectEqualStrings("std.List", std_id.logical_path);
}

test "module loader rejects an active graph-resolution cycle" {
    var loader = ModuleLoader.init(std.testing.allocator, ".", null, null);
    defer loader.deinit();

    var mod = LoadedModule{
        .id = .{ .package = "workspace", .logical_path = "example" },
        .program = .{ .imports = &.{}, .definitions = &.{}, .package = null },
        .source = "",
        .file_path = "example.ko",
        .resolution_state = .resolving,
    };

    try std.testing.expectError(error.ImportCycle, loader.resolveModuleImports(&mod));
}

fn closeFd(fd: fdio.fd_t) void {
    fdio.close(fd);
}

fn readFd(fd: fdio.fd_t, buf: []u8) !usize {
    const n = fdio.read(fd, buf);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}
