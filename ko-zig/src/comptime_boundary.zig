//! Compiler-owned boundary for compile-time execution.
//!
//! This module deliberately contains no evaluator and performs no host I/O.
//! It defines the data and policy that an evaluator must use when it is added.

const std = @import("std");

pub const Capability = enum(u8) {
    file_read,
    environment_read,
    network,
    process,
    clock,
    random,
    compiler_ast_mutation,
};

pub const CapabilitySet = struct {
    bits: u16 = 0,

    pub fn grant(self: *CapabilitySet, capability: Capability) void {
        self.bits |= @as(u16, 1) << @as(u4, @intCast(@backingInt(capability)));
    }

    pub fn allows(self: CapabilitySet, capability: Capability) bool {
        return (self.bits & (@as(u16, 1) << @as(u4, @intCast(@backingInt(capability))))) != 0;
    }
};

pub const Effect = enum {
    pure,
    tracked,
    opaque_effect,
};

pub const CacheStage = enum {
    parsed,
    resolved,
    interface,
    typed_hir,
    lir,
    object,
};

pub const BuildConfiguration = struct {
    compiler_build: []const u8,
    language_version: []const u8,
    target: []const u8,
    flags: []const u8,
    representation_version: []const u8,
    llvm_version: []const u8,
};

pub const CacheInputs = struct {
    compiler_build: []const u8,
    language_version: []const u8,
    target: []const u8,
    flags: []const u8,
    module_id: []const u8,
    source_hash: u64,
    interface_hash: u64,
    dependency_hash: u64,
    stdlib_hash: u64,
    comptime_input_hash: u64,
    representation_version: []const u8,
    llvm_version: []const u8,
};

pub fn cacheKey(stage: CacheStage, inputs: CacheInputs) u64 {
    var stage_buf: [1]u8 = .{@backingInt(stage)};
    var source_buf: [8]u8 = undefined;
    var interface_buf: [8]u8 = undefined;
    var dependency_buf: [8]u8 = undefined;
    var stdlib_buf: [8]u8 = undefined;
    var comptime_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &source_buf, inputs.source_hash, .little);
    std.mem.writeInt(u64, &interface_buf, inputs.interface_hash, .little);
    std.mem.writeInt(u64, &dependency_buf, inputs.dependency_hash, .little);
    std.mem.writeInt(u64, &stdlib_buf, inputs.stdlib_hash, .little);
    std.mem.writeInt(u64, &comptime_buf, inputs.comptime_input_hash, .little);
    return fingerprint(&.{
        &stage_buf,
        inputs.compiler_build,
        inputs.language_version,
        inputs.target,
        inputs.flags,
        inputs.module_id,
        &source_buf,
        &interface_buf,
        &dependency_buf,
        &stdlib_buf,
        &comptime_buf,
        inputs.representation_version,
        inputs.llvm_version,
    });
}

pub fn isCacheable(effect: Effect) bool {
    return effect != .opaque_effect;
}

pub const Event = union(enum) {
    compilation_started: struct { configuration_hash: u64 },
    module_discovered: struct { module_id: []const u8, source_hash: u64 },
    module_typechecked: struct { module_id: []const u8, interface_hash: u64 },
    comptime_evaluated: struct { action_id: []const u8, input_hash: u64, result_hash: u64, effect: Effect },
    cache_hit: struct { stage: []const u8, key: u64 },
    cache_miss: struct { stage: []const u8, key: u64, reason: []const u8 },
    artifact_produced: struct { kind: []const u8, hash: u64 },
    ast_mutated: struct { action_id: []const u8, module_id: []const u8 },
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    capabilities: CapabilitySet,
    events: std.ArrayList(Event) = .empty,
    cacheable: bool = true,

    pub fn init(allocator: std.mem.Allocator, capabilities: CapabilitySet) Context {
        return .{ .allocator = allocator, .capabilities = capabilities };
    }

    pub fn deinit(self: *Context) void {
        self.events.deinit(self.allocator);
    }

    pub fn begin(self: *Context, configuration_hash: u64) !void {
        try self.events.append(self.allocator, .{ .compilation_started = .{ .configuration_hash = configuration_hash } });
    }

    pub fn moduleDiscovered(self: *Context, module_id: []const u8, source: []const u8) !void {
        try self.events.append(self.allocator, .{ .module_discovered = .{ .module_id = module_id, .source_hash = fingerprint(&.{source}) } });
    }

    pub fn moduleTypechecked(self: *Context, module_id: []const u8, interface_hash: u64) !void {
        try self.events.append(self.allocator, .{ .module_typechecked = .{ .module_id = module_id, .interface_hash = interface_hash } });
    }

    pub fn comptimeEvaluated(self: *Context, action_id: []const u8, effect: Effect, input_hash: u64, result_hash: u64) !void {
        if (!isCacheable(effect)) self.cacheable = false;
        try self.events.append(self.allocator, .{ .comptime_evaluated = .{ .action_id = action_id, .input_hash = input_hash, .result_hash = result_hash, .effect = effect } });
    }

    pub fn cacheHit(self: *Context, stage: []const u8, key: u64) !void {
        try self.events.append(self.allocator, .{ .cache_hit = .{ .stage = stage, .key = key } });
    }

    pub fn cacheMiss(self: *Context, stage: []const u8, key: u64, reason: []const u8) !void {
        try self.events.append(self.allocator, .{ .cache_miss = .{ .stage = stage, .key = key, .reason = reason } });
    }

    pub fn artifactProduced(self: *Context, kind: []const u8, bytes: []const u8) !void {
        try self.events.append(self.allocator, .{ .artifact_produced = .{ .kind = kind, .hash = fingerprint(&.{bytes}) } });
    }

    pub fn recordAstMutation(self: *Context, action_id: []const u8, module_id: []const u8) !void {
        if (!self.capabilities.allows(.compiler_ast_mutation)) return error.CapabilityDenied;
        self.cacheable = false;
        try self.events.append(self.allocator, .{ .ast_mutated = .{ .action_id = action_id, .module_id = module_id } });
    }
};

pub fn fingerprint(parts: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (parts) |part| {
        hasher.update(part);
        hasher.update(&.{0});
    }
    return hasher.final();
}

test "compile-time effects determine cache eligibility" {
    try std.testing.expect(isCacheable(.pure));
    try std.testing.expect(isCacheable(.tracked));
    try std.testing.expect(!isCacheable(.opaque_effect));
}

test "compile-time context records events and invalidates opaque work" {
    var context = Context.init(std.testing.allocator, .{});
    defer context.deinit();
    try context.begin(42);
    try context.comptimeEvaluated("action", .opaque_effect, 1, 2);
    try std.testing.expectEqual(@as(usize, 2), context.events.items.len);
    try std.testing.expect(!context.cacheable);
}

test "AST mutation requires its compiler capability" {
    var context = Context.init(std.testing.allocator, .{});
    defer context.deinit();
    try std.testing.expectError(error.CapabilityDenied, context.recordAstMutation("action", "module"));
    context.capabilities.grant(.compiler_ast_mutation);
    try context.recordAstMutation("action", "module");
    try std.testing.expect(!context.cacheable);
}

test "cache keys include stage and compiler inputs" {
    const inputs = CacheInputs{
        .compiler_build = "dev",
        .language_version = "1",
        .target = "x86_64-linux",
        .flags = "debug",
        .module_id = "workspace:main",
        .source_hash = 1,
        .interface_hash = 2,
        .dependency_hash = 3,
        .stdlib_hash = 4,
        .comptime_input_hash = 5,
        .representation_version = "repr-1",
        .llvm_version = "23",
    };
    const parsed = cacheKey(.parsed, inputs);
    const object = cacheKey(.object, inputs);
    try std.testing.expect(parsed != object);
    try std.testing.expectEqual(parsed, cacheKey(.parsed, inputs));
}
