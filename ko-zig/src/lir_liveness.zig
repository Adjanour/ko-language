//! Conservative ownership-driven cleanup for LIR.
//!
//! This pass releases only owned allocations with non-escaping `is_unique`
//! uses. It handles straight-line blocks and acyclic branch graphs. Values
//! converted to the runtime integer representation, passed to calls, stored,
//! returned, or flowing through loops remain for the later global pass.

const std = @import("std");
const lir = @import("lir.zig");

pub const Error = std.mem.Allocator.Error;

pub fn run(allocator: std.mem.Allocator, fns: []lir.LirFn) Error!void {
    for (fns) |*function| {
        // LIR lowering owns these block arrays. `LirFn` exposes a const slice
        // to codegen, so this mutating optimization pass narrows that boundary.
        for (@constCast(function.blocks), 0..) |*block, block_index| {
            try releaseLocalOwnedAllocations(allocator, function.*, block, block_index);
        }
        try releaseCfgOwnedAllocations(allocator, function.*);
    }
}

fn releaseLocalOwnedAllocations(allocator: std.mem.Allocator, function: lir.LirFn, block: *lir.BasicBlock, block_index: usize) Error!void {
    var drops_after = std.AutoHashMap(usize, std.ArrayList(lir.LocalId)).init(allocator);
    defer {
        var values = drops_after.valueIterator();
        while (values.next()) |drops| drops.deinit(allocator);
        drops_after.deinit();
    }

    for (block.body, 0..) |stmt, alloc_index| {
        const alloc = switch (stmt) {
            .assign => |assign| switch (assign.value) {
                .alloc => |value| value,
                else => continue,
            },
            else => continue,
        };
        if (alloc.ownership != .owned) continue;

        const allocation_id = stmt.assign.dest;
        if (usedOutsideBlock(function, block_index, allocation_id)) continue;
        var last_use = alloc_index;
        var safe = true;
        for (block.body[alloc_index + 1 ..], alloc_index + 1..) |later, index| {
            if (!statementUses(later, allocation_id)) continue;
            switch (later) {
                .assign => |assign| switch (assign.value) {
                    .is_unique => {},
                    else => safe = false,
                },
                else => safe = false,
            }
            last_use = index;
        }
        if (terminatorUses(block.terminator, allocation_id)) safe = false;
        if (!safe) continue;

        const gop = try drops_after.getOrPut(last_use);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, allocation_id);
    }

    if (drops_after.count() == 0) return;
    var body = std.ArrayList(lir.LirStmt).empty;
    defer body.deinit(allocator);
    for (block.body, 0..) |stmt, index| {
        try body.append(allocator, stmt);
        if (drops_after.getPtr(index)) |drops| {
            for (drops.items) |id| try body.append(allocator, .{ .effect = .{ .decref = id } });
        }
    }
    block.body = try body.toOwnedSlice(allocator);
}

/// Extend the local rule across an acyclic CFG. To guarantee that the value
/// exists on every cleanup path, this deliberately considers only allocations
/// made in the entry block.
fn releaseCfgOwnedAllocations(allocator: std.mem.Allocator, function: lir.LirFn) Error!void {
    if (function.blocks.len == 0) return;
    if (hasControlFlowCycle(allocator, function)) return releaseAtReturnExits(allocator, function);
    const entry = function.blocks[0];
    for (entry.body, 0..) |stmt, statement_index| {
        const alloc = switch (stmt) {
            .assign => |assign| switch (assign.value) {
                .alloc => |value| value,
                else => continue,
            },
            else => continue,
        };
        if (alloc.ownership != .owned) continue;
        const id = stmt.assign.dest;
        if (!hasOnlyUniquenessUses(function, id, 0, statement_index)) continue;

        const visited = try allocator.alloc(bool, function.blocks.len);
        defer allocator.free(visited);
        @memset(visited, false);
        try placeCfgDrops(allocator, function, 0, id, visited);
    }
}

/// A value allocated before a loop remains live around its back-edge. When it
/// has no escaping use, releasing it at each normal return exit is safe on
/// every finite iteration count (including zero). Switches use the same
/// conservative exit rule until their individual cases are dataflow-planned.
fn releaseAtReturnExits(allocator: std.mem.Allocator, function: lir.LirFn) Error!void {
    const entry = function.blocks[0];
    for (entry.body, 0..) |statement, statement_index| {
        const alloc = switch (statement) {
            .assign => |assign| switch (assign.value) {
                .alloc => |value| value,
                else => continue,
            },
            else => continue,
        };
        if (alloc.ownership != .owned) continue;
        const id = statement.assign.dest;
        if (!hasOnlyUniquenessUses(function, id, 0, statement_index)) continue;
        for (@constCast(function.blocks)) |*block| {
            if (block.terminator != .ret) continue;
            try appendDrop(allocator, block, id, null);
        }
    }
}

fn usedOutsideBlock(function: lir.LirFn, current: usize, id: lir.LocalId) bool {
    for (function.blocks, 0..) |other, index| {
        if (index == current) continue;
        for (other.body) |statement| if (statementUses(statement, id)) return true;
        if (terminatorUses(other.terminator, id)) return true;
    }
    return false;
}

fn hasOnlyUniquenessUses(function: lir.LirFn, id: lir.LocalId, allocation_block: usize, allocation_statement: usize) bool {
    for (function.blocks, 0..) |block, block_index| {
        for (block.body, 0..) |statement, statement_index| {
            if (block_index == allocation_block and statement_index == allocation_statement) continue;
            if (!statementUsesAlias(function, statement, id)) continue;
            switch (statement) {
                .assign => |assign| switch (assign.value) {
                    .is_unique => {},
                    .local, .ptrtoint => {},
                    .call => |call| if (!callBorrowsAliases(function, call, id)) return false,
                    else => return false,
                },
                else => return false,
            }
        }
        if (terminatorUsesAlias(function, block.terminator, id) and !isForwardingTerminator(function, block.terminator, id)) return false;
    }
    return true;
}

fn placeCfgDrops(allocator: std.mem.Allocator, function: lir.LirFn, block_index: usize, id: lir.LocalId, visited: []bool) Error!void {
    if (visited[block_index]) return;
    visited[block_index] = true;
    const block = &@constCast(function.blocks)[block_index];
    const use_index = lastUniquenessUse(function, block.*, id);
    const successors_use_value = successorsHaveUse(function, block_index, id);
    if (!successors_use_value) {
        try appendDrop(allocator, block, id, use_index);
        return;
    }
    switch (block.terminator) {
        .br => |target| try placeCfgDrops(allocator, function, blockIndex(function, target.target) orelse return, id, visited),
        .cond_br => |branch| {
            try placeCfgDrops(allocator, function, blockIndex(function, branch.then.target) orelse return, id, visited);
            try placeCfgDrops(allocator, function, blockIndex(function, branch.else_.target) orelse return, id, visited);
        },
        else => {},
    }
}

fn lastUniquenessUse(function: lir.LirFn, block: lir.BasicBlock, id: lir.LocalId) ?usize {
    var result: ?usize = null;
    for (block.body, 0..) |statement, index| {
        if (!statementUsesAlias(function, statement, id)) continue;
        switch (statement) {
            .assign => |assign| {
                if (assign.value == .is_unique) result = index;
            },
            else => {},
        }
    }
    return result;
}

fn appendDrop(allocator: std.mem.Allocator, block: *lir.BasicBlock, id: lir.LocalId, after: ?usize) Error!void {
    var body = std.ArrayList(lir.LirStmt).empty;
    defer body.deinit(allocator);
    for (block.body, 0..) |statement, index| {
        try body.append(allocator, statement);
        if (after != null and after.? == index) try body.append(allocator, .{ .effect = .{ .decref = id } });
    }
    if (after == null) try body.append(allocator, .{ .effect = .{ .decref = id } });
    block.body = try body.toOwnedSlice(allocator);
}

fn statementUsesAlias(function: lir.LirFn, statement: lir.LirStmt, root: lir.LocalId) bool {
    for (0..function.locals.len) |id| {
        if (isAlias(function, id, root, function.locals.len) and statementUses(statement, id)) return true;
    }
    return false;
}

fn terminatorUsesAlias(function: lir.LirFn, terminator: lir.LirTerminator, root: lir.LocalId) bool {
    for (0..function.locals.len) |id| {
        if (isAlias(function, id, root, function.locals.len) and terminatorUses(terminator, id)) return true;
    }
    return false;
}

fn isForwardingTerminator(function: lir.LirFn, terminator: lir.LirTerminator, root: lir.LocalId) bool {
    return switch (terminator) {
        .br => |target| branchForwardsOnlyAliases(function, target, root),
        .cond_br => |branch| branchForwardsOnlyAliases(function, branch.then, root) and branchForwardsOnlyAliases(function, branch.else_, root),
        else => false,
    };
}

fn callBorrowsAliases(function: lir.LirFn, call: lir.CallValue, root: lir.LocalId) bool {
    if (isAlias(function, call.func, root, function.locals.len)) return false;
    for (call.args, 0..) |arg, index| {
        if (isAlias(function, arg, root, function.locals.len) and call.ownership.argument(index) != .borrow) return false;
    }
    return true;
}

fn branchForwardsOnlyAliases(function: lir.LirFn, target: lir.BrTarget, root: lir.LocalId) bool {
    const target_index = blockIndex(function, target.target) orelse return false;
    const params = function.blocks[target_index].params;
    if (params.len != target.args.len) return false;
    for (target.args, 0..) |arg, index| {
        if (!isAlias(function, arg, root, function.locals.len)) continue;
        if (!isAlias(function, params[index], root, function.locals.len)) return false;
    }
    return true;
}

/// Resolve aliases without allocating. The depth bound makes cyclic CFGs
/// conservative: loops are deferred by the caller before this result is used.
fn isAlias(function: lir.LirFn, candidate: lir.LocalId, root: lir.LocalId, depth: usize) bool {
    if (candidate == root) return true;
    if (depth == 0) return false;
    for (function.blocks) |block| {
        for (block.body) |statement| switch (statement) {
            .assign => |assign| if (assign.dest == candidate) switch (assign.value) {
                .local, .ptrtoint => |source| if (isAlias(function, source, root, depth - 1)) return true,
                else => {},
            },
            else => {},
        };
    }
    for (function.blocks) |block| {
        for (block.params, 0..) |param, parameter_index| {
            if (param != candidate) continue;
            for (function.blocks) |predecessor| switch (predecessor.terminator) {
                .br => |target| if (target.target == block.id and parameter_index < target.args.len and isAlias(function, target.args[parameter_index], root, depth - 1)) return true,
                .cond_br => |branch| {
                    if (branch.then.target == block.id and parameter_index < branch.then.args.len and isAlias(function, branch.then.args[parameter_index], root, depth - 1)) return true;
                    if (branch.else_.target == block.id and parameter_index < branch.else_.args.len and isAlias(function, branch.else_.args[parameter_index], root, depth - 1)) return true;
                },
                else => {},
            };
        }
    }
    return false;
}

fn successorsHaveUse(function: lir.LirFn, block_index: usize, id: lir.LocalId) bool {
    return switch (function.blocks[block_index].terminator) {
        .br => |target| hasFutureUse(function, blockIndex(function, target.target) orelse return false, id),
        .cond_br => |branch| hasFutureUse(function, blockIndex(function, branch.then.target) orelse return false, id) or hasFutureUse(function, blockIndex(function, branch.else_.target) orelse return false, id),
        else => false,
    };
}

fn hasFutureUse(function: lir.LirFn, block_index: usize, id: lir.LocalId) bool {
    if (lastUniquenessUse(function, function.blocks[block_index], id) != null) return true;
    return successorsHaveUse(function, block_index, id);
}

fn blockIndex(function: lir.LirFn, id: lir.BlockId) ?usize {
    for (function.blocks, 0..) |block, index| if (block.id == id) return index;
    return null;
}

fn hasControlFlowCycle(allocator: std.mem.Allocator, function: lir.LirFn) bool {
    const colors = allocator.alloc(u2, function.blocks.len) catch return true;
    defer allocator.free(colors);
    @memset(colors, 0);
    return visitForCycle(function, 0, colors);
}

fn visitForCycle(function: lir.LirFn, index: usize, colors: []u2) bool {
    if (colors[index] == 1) return true;
    if (colors[index] == 2) return false;
    colors[index] = 1;
    const cycle = switch (function.blocks[index].terminator) {
        .br => |target| visitForCycle(function, blockIndex(function, target.target) orelse return true, colors),
        .cond_br => |branch| visitForCycle(function, blockIndex(function, branch.then.target) orelse return true, colors) or visitForCycle(function, blockIndex(function, branch.else_.target) orelse return true, colors),
        .switch_ => true,
        else => false,
    };
    colors[index] = 2;
    return cycle;
}

fn statementUses(statement: lir.LirStmt, id: lir.LocalId) bool {
    return switch (statement) {
        .assign => |assign| valueUses(assign.value, id),
        .store => |store| store.dest == id or store.value == id,
        .effect => |value| valueUses(value, id),
    };
}

fn valueUses(value: lir.LirValue, id: lir.LocalId) bool {
    return switch (value) {
        .local, .load, .incref, .decref, .is_unique, .ptrtoint => |local| local == id,
        .inttoptr => |v| v.val == id,
        .zext, .trunc, .bitcast => |v| v.val == id,
        .call => |call| sliceContains(call.args, id) or call.func == id,
        .make_closure => |closure| sliceContains(closure.captures, id),
        .extract_value => |extract| extract.aggregate == id,
        .insert_value => |insert| insert.aggregate == id or insert.value == id,
        .get_element_ptr => |gep| gep.ptr == id or sliceContains(gep.indices, id),
        .primop => |primop| sliceContains(primop.args, id),
        else => false,
    };
}

fn terminatorUses(terminator: lir.LirTerminator, id: lir.LocalId) bool {
    return switch (terminator) {
        .ret => |value| value == id,
        .tail_call => |call| sliceContains(call.args, id) or call.func == id,
        .br => |target| sliceContains(target.args, id),
        .cond_br => |branch| branch.cond == id or sliceContains(branch.then.args, id) or sliceContains(branch.else_.args, id),
        .switch_ => |switch_| blk: {
            if (switch_.val == id or sliceContains(switch_.default.args, id)) break :blk true;
            for (switch_.cases) |case_| if (sliceContains(case_.target.args, id)) break :blk true;
            break :blk false;
        },
        .unreachable_ => false,
    };
}

fn sliceContains(ids: []const lir.LocalId, id: lir.LocalId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}
