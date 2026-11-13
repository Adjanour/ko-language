const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const hir_lower = @import("hir_lower.zig");
const hir_fold = @import("hir_fold.zig");
const hir_dce = @import("hir_dce.zig");
const hir_check = @import("hir_check.zig");
const hir_beta = @import("hir_beta.zig");
const hir_let_simpl = @import("hir_let_simpl.zig");
const hir_known_match = @import("hir_known_match.zig");
const linearity_mod = @import("linearity.zig");
const module_loader_mod = @import("module_loader.zig");
const diagnostics_mod = @import("diagnostics.zig");
const monomorphize_mod = @import("monomorphize.zig");
const comptime_boundary = @import("comptime_boundary.zig");
const module_interface = @import("module_interface.zig");
const symbol_index = @import("symbol_index.zig");
const compiler_cache = @import("compiler_cache.zig");

pub const Prepared = struct {
    program: parser.Program,
    allocator: std.mem.Allocator,
    loader: *module_loader_mod.ModuleLoader,
    inferer: *typecheck.Inferer,
    hir: *hir_lower.HirLower,
    typecheck_time: u64,
    comptime_context: *comptime_boundary.Context,
    interface_hash: u64,
    dependency_hash: u64,
    symbols: *symbol_index.Index,
    interface: *module_interface.ModuleInterface,

    pub fn deinit(self: *Prepared) void {
        self.hir.deinit();
        self.allocator.destroy(self.hir);
        self.inferer.deinit();
        self.allocator.destroy(self.inferer);
        self.loader.deinit();
        self.allocator.destroy(self.loader);
        self.comptime_context.deinit();
        self.allocator.destroy(self.comptime_context);
        self.symbols.deinit();
        self.allocator.destroy(self.symbols);
        self.interface.deinit();
        self.allocator.destroy(self.interface);
    }
};

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn hasWarnings(diags: *const diagnostics_mod.DiagnosticList) bool {
    for (diags.items.items) |diagnostic| {
        if (diagnostic.severity == .warning) return true;
    }
    return false;
}

fn importedInterfaceFingerprint(allocator: std.mem.Allocator, inferer: *const typecheck.Inferer) u64 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var owned_hashes = std.ArrayList([]u8).empty;
    defer {
        for (owned_hashes.items) |part| allocator.free(part);
        owned_hashes.deinit(allocator);
    }
    for (inferer.imported_modules.items) |imported| {
        parts.append(allocator, imported.module.file_path) catch return 0;
        const owned = std.fmt.allocPrint(allocator, "{d}", .{imported.interface_hash}) catch return 0;
        parts.append(allocator, owned) catch {
            allocator.free(owned);
            return 0;
        };
        owned_hashes.append(allocator, owned) catch return 0;
    }
    return comptime_boundary.fingerprint(parts.items);
}

fn persistImportedInterfaces(io: Io, allocator: std.mem.Allocator, cache: *compiler_cache.Cache, configuration: comptime_boundary.BuildConfiguration, inferer: *typecheck.Inferer) !void {
    var visited = std.AutoHashMap(*typecheck.Inferer, void).init(allocator);
    defer visited.deinit();
    try persistImportedInterfacesVisit(io, allocator, cache, configuration, inferer, &visited);
}

fn persistImportedInterfacesVisit(io: Io, allocator: std.mem.Allocator, cache: *compiler_cache.Cache, configuration: comptime_boundary.BuildConfiguration, inferer: *typecheck.Inferer, visited: *std.AutoHashMap(*typecheck.Inferer, void)) !void {
    if (visited.contains(inferer)) return;
    try visited.put(inferer, {});
    for (inferer.imported_modules.items) |imported| {
        var interface = try module_interface.ModuleInterface.build(allocator, imported.module.file_path, &imported.module.program, imported.inferer);
        defer interface.deinit();
        const serialized = try interface.serialize(allocator);
        defer allocator.free(serialized);
        const key = comptime_boundary.cacheKey(.interface, .{
            .compiler_build = configuration.compiler_build,
            .language_version = configuration.language_version,
            .target = configuration.target,
            .flags = configuration.flags,
            .module_id = imported.module.file_path,
            .source_hash = comptime_boundary.fingerprint(&.{imported.module.source}),
            .interface_hash = 0,
            .dependency_hash = 0,
            .stdlib_hash = 0,
            .comptime_input_hash = 0,
            .representation_version = configuration.representation_version,
            .llvm_version = configuration.llvm_version,
        });
        try cache.put(io, Io.Dir.cwd(), .interface, key, serialized);
        try persistImportedInterfacesVisit(io, allocator, cache, configuration, imported.inferer, visited);
    }
}

pub fn prepare(
    io: Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    source: [:0]const u8,
    program: parser.Program,
    parse_time: u64,
    timer: u64,
    diagnostics: *diagnostics_mod.DiagnosticList,
    enabled_warnings: diagnostics_mod.WarningSet,
    skip_linearity: bool,
    warnings_as_errors: bool,
    cache: ?*compiler_cache.Cache,
    configuration: comptime_boundary.BuildConfiguration,
    report_error: anytype,
) !Prepared {
    const base_dir = std.fs.path.dirname(filename) orelse ".";
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch ".";
    const loader = try allocator.create(module_loader_mod.ModuleLoader);
    loader.* = module_loader_mod.ModuleLoader.init(allocator, base_dir, null, exe_dir);
    if (cache) |store| loader.configureInterfaceCache(io, store, configuration);
    errdefer {
        loader.deinit();
        allocator.destroy(loader);
    }

    const comptime_context = try allocator.create(comptime_boundary.Context);
    comptime_context.* = comptime_boundary.Context.init(allocator, .{});
    errdefer {
        comptime_context.deinit();
        allocator.destroy(comptime_context);
    }
    try comptime_context.begin(comptime_boundary.fingerprint(&.{source}));
    try comptime_context.moduleDiscovered(filename, source);

    loader.resolveImportGraph(program.imports) catch |err| {
        report_error(io, filename, null, "module resolution error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // This pass establishes checked program facts before specialization. The
    // current specializer still derives substitutions from syntax; the next
    // migration replaces that inference with these checked call-site facts.
    var discovery = typecheck.Inferer.init(allocator);
    defer discovery.deinit();
    discovery.module_loader = loader;
    discovery.global.module_id = filename;
    discovery.inferProgram(&program) catch |err| {
        if (discovery.last_error) |context| {
            try diagnostics.addErrorCtx(
                context.message orelse @errorName(err),
                context.loc,
                context.note,
                context.help,
            );
        } else {
            try diagnostics.addError(@errorName(err), null);
        }
    };
    if (diagnostics.has_errors) {
        diagnostics.emitAll(io, filename, source);
        std.process.exit(1);
    }

    var mono = monomorphize_mod.Monomorphizer.init(allocator);
    defer mono.deinit();
    const mono_result = mono.runTyped(program, &discovery) catch |err| {
        std.log.err("Monomorphization error: {}", .{err});
        return err;
    };

    const combined = try allocator.alloc(parser.Definition, mono_result.definitions.len + mono_result.specialized_fns.len);
    for (mono_result.definitions, 0..) |definition, index| combined[index] = definition;
    for (mono_result.specialized_fns, 0..) |specialized, index| {
        combined[mono_result.definitions.len + index] = .{ .fn_def = specialized };
    }
    var prepared_program = program;
    prepared_program.definitions = combined;

    const inferer = try allocator.create(typecheck.Inferer);
    inferer.* = typecheck.Inferer.init(allocator);
    errdefer {
        inferer.deinit();
        allocator.destroy(inferer);
    }
    inferer.module_loader = loader;
    inferer.global.module_id = filename;
    inferer.diagnostics = diagnostics;
    inferer.enabled_warnings = enabled_warnings;

    inferer.inferProgram(&prepared_program) catch |err| {
        if (inferer.last_error) |context| {
            try diagnostics.addErrorCtx(
                context.message orelse @errorName(err),
                context.loc,
                context.note,
                context.help,
            );
        } else {
            try diagnostics.addError(@errorName(err), null);
        }
    };
    try comptime_context.moduleTypechecked(filename, comptime_boundary.fingerprint(&.{source}));
    const typecheck_time = nowNs() - timer - parse_time;

    const interface = try allocator.create(module_interface.ModuleInterface);
    interface.* = try module_interface.ModuleInterface.build(allocator, filename, &prepared_program, inferer);
    errdefer {
        interface.deinit();
        allocator.destroy(interface);
    }
    const dependency_hash = importedInterfaceFingerprint(allocator, inferer);
    if (cache) |store| {
        const interface_key = comptime_boundary.cacheKey(.interface, .{
            .compiler_build = configuration.compiler_build,
            .language_version = configuration.language_version,
            .target = configuration.target,
            .flags = configuration.flags,
            .module_id = filename,
            .source_hash = comptime_boundary.fingerprint(&.{source}),
            .interface_hash = 0,
            .dependency_hash = 0,
            .stdlib_hash = 0,
            .comptime_input_hash = 0,
            .representation_version = configuration.representation_version,
            .llvm_version = configuration.llvm_version,
        });
        const serialized = try interface.serialize(allocator);
        defer allocator.free(serialized);
        const cached = store.get(io, Io.Dir.cwd(), .interface, interface_key) catch |err| blk: switch (err) {
            error.CorruptArtifact => {
                try comptime_context.cacheMiss("interface", interface_key, "corrupt_artifact");
                break :blk null;
            },
            else => return err,
        };
        if (cached) |bytes| {
            defer allocator.free(bytes);
            const restored_result = module_interface.ModuleInterface.deserialize(allocator, filename, bytes) catch null;
            if (restored_result) |restored_value| {
                var restored = restored_value;
                defer restored.deinit();
                if (restored.hash == interface.hash) {
                    try comptime_context.cacheHit("interface", interface_key);
                } else {
                    try comptime_context.cacheMiss("interface", interface_key, "source_changed");
                    try store.put(io, Io.Dir.cwd(), .interface, interface_key, serialized);
                }
            } else {
                try comptime_context.cacheMiss("interface", interface_key, "corrupt_interface");
                try store.put(io, Io.Dir.cwd(), .interface, interface_key, serialized);
            }
        } else {
            try comptime_context.cacheMiss("interface", interface_key, "source_changed");
            try store.put(io, Io.Dir.cwd(), .interface, interface_key, serialized);
            try comptime_context.artifactProduced("interface", serialized);
        }
        try persistImportedInterfaces(io, allocator, store, configuration, inferer);
    }
    const symbols = try allocator.create(symbol_index.Index);
    symbols.* = try symbol_index.buildForProgram(allocator, filename, &prepared_program, inferer);
    errdefer {
        symbols.deinit();
        allocator.destroy(symbols);
    }
    inferer.global.resolver = .{ .context = symbols, .lookup = symbol_index.resolveScheme };

    if (diagnostics.has_errors) {
        diagnostics.emitAll(io, filename, source);
        std.process.exit(1);
    }

    const hir = try allocator.create(hir_lower.HirLower);
    hir.* = hir_lower.HirLower.init(allocator, inferer);
    errdefer {
        hir.deinit();
        allocator.destroy(hir);
    }
    hir.lowerProgram(&prepared_program) catch |err| {
        report_error(io, filename, null, "HIR lowering error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    if (!skip_linearity) {
        var linearity = linearity_mod.LinearityChecker.init(allocator, &hir.expressions, diagnostics);
        defer linearity.deinit();
        linearity.run(hir.roots.items, hir.defs.items);
        if (diagnostics.has_errors) {
            diagnostics.emitAll(io, filename, source);
            std.process.exit(1);
        }
    }

    var beta = hir_beta.HirBeta.init(allocator, &hir.expressions);
    beta.run();
    var check = hir_check.HirCheck.init(allocator, &hir.expressions, diagnostics);
    check.run();
    if (diagnostics.has_errors) {
        diagnostics.emitAll(io, filename, source);
        std.process.exit(1);
    }
    if (hasWarnings(diagnostics)) diagnostics.emitAll(io, filename, source);
    if (warnings_as_errors and hasWarnings(diagnostics)) std.process.exit(1);

    var let_simpl = hir_let_simpl.HirLetSimpl.init(allocator, &hir.expressions);
    let_simpl.run();
    var known = hir_known_match.HirKnownMatch.init(allocator, &hir.expressions);
    known.run();
    var fold = hir_fold.HirFold.init(allocator, &hir.expressions);
    fold.run();
    var dce = hir_dce.HirDce.init(allocator, &hir.expressions);
    dce.run(hir.roots.items);

    return .{
        .program = prepared_program,
        .allocator = allocator,
        .loader = loader,
        .inferer = inferer,
        .hir = hir,
        .typecheck_time = typecheck_time,
        .comptime_context = comptime_context,
        .interface_hash = interface.hash,
        .dependency_hash = dependency_hash,
        .symbols = symbols,
        .interface = interface,
    };
}
