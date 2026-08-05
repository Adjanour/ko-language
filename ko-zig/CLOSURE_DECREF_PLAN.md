# Closure Capture Decref Improvement Plan

## Problem Statement

The current closure capture decref implementation has a critical type_tag mismatch:

- `typeToTag` in typecheck.zig returns **type-based tags**: int=0, float=1, bool=2, char=3, string=4, unit=5, con=6, record=7, arrow=8, tuple=9
- `ko_decref_closure` in stdlib_codegen.zig checks for **memory-layout tags**: 0=ref, 1=constructor, 2=tuple, 3=record, 4=string, 6=arrow

This works by coincidence because `ko_decref_value` with type_tag=0 and arity=0 does nothing. But it's semantically wrong and fragile.

Additionally, partial app closures store all type_tags as 0 (skip decref), which means:
1. Applied heap-allocated args are NOT decreffed when the closure is freed (memory leak)
2. Unapplied slots contain uninitialized memory that could be interpreted as pointers

## Solution: Option B - Fix ko_decref_closure to Use Type-Based Tags

### Why Option B?

1. **Semantically correct**: Uses actual type information from the typechecker
2. **Consistent**: Aligns with `typeToTag` which is the source of truth for types
3. **Maintainable**: Clear logic - "if type is heap-allocated, decref it"
4. **Extensible**: Adding new types only requires updating `typeToTag` and `ko_decref_closure`

### Implementation Plan

#### Step 1: Update `ko_decref_closure` to Use Type-Based Tags

**File:** `src/stdlib_codegen.zig`

Change the heap type check from memory-layout tags to type-based tags:

```zig
// Current (WRONG):
const is_heap = core.LLVMBuildOr(self.builder,
    core.LLVMBuildOr(self.builder,
        core.LLVMBuildOr(self.builder,
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 0, 0), "is_ref"),  // WRONG: 0=int
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 1, 0), "is_ctor"),  // WRONG: 1=float
            "or1"),
        core.LLVMBuildOr(self.builder,
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 2, 0), "is_tuple"), // WRONG: 2=bool
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 3, 0), "is_record"),// WRONG: 3=char
            "or2"), "or3"),
    core.LLVMBuildOr(self.builder,
        core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 4, 0), "is_string"),  // OK: 4=string
        core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 6, 0), "is_arrow"),   // OK: 6=con (WRONG: should be record/arrow)
        "or4"),
    "is_heap");

// New (CORRECT):
// Heap types from typeToTag: 4=string, 6=con, 7=record, 8=arrow, 9=tuple
// Scalar types: 0=int, 1=float, 2=bool, 3=char, 5=unit
// Skip tag: -1 (for unapplied partial app slots)
const is_heap = core.LLVMBuildOr(self.builder,
    core.LLVMBuildOr(self.builder,
        core.LLVMBuildOr(self.builder,
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 4, 0), "is_string"),
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 6, 0), "is_con"), "or1"),
        core.LLVMBuildOr(self.builder,
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 7, 0), "is_record"),
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 8, 0), "is_arrow"), "or2"), "or3"),
    core.LLVMBuildOr(self.builder,
        core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 9, 0), "is_tuple"),
        core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), -1, 0), "is_skip"), "or4"),
    "is_heap_or_skip");
```

Wait, we also need to handle the skip tag. Let me reconsider...

Actually, the skip tag should NOT be treated as heap. We should check for skip FIRST and skip the decref:

```zig
// Check if type_tag == -1 (skip, for unapplied partial app slots)
const is_skip = core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), -1, 0), "is_skip");

// Heap types: 4=string, 6=con, 7=record, 8=arrow, 9=tuple
const is_heap = core.LLVMBuildOr(self.builder,
    core.LLVMBuildOr(self.builder,
        core.LLVMBuildOr(self.builder,
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 4, 0), "is_string"),
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 6, 0), "is_con"), "or1"),
        core.LLVMBuildOr(self.builder,
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 7, 0), "is_record"),
            core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 8, 0), "is_arrow"), "or2"), "or3"),
    core.LLVMBuildICmp(self.builder, .LLVMIntEQ, type_tag, core.LLVMConstInt(self.i64Type(), 9, 0), "is_tuple"),
    "is_heap");

// Skip if type_tag == -1 (unapplied slot) OR not heap-allocated
const should_skip = core.LLVMBuildOr(self.builder, is_skip, core.LLVMBuildNot(self.builder, is_heap, "not_heap"), "should_skip");
self.buildCondBranch(should_skip, loop_next, decref_bb);
```

#### Step 2: Update `createPartialApp` to Store Actual Type Tags

**File:** `src/codegen.zig`

The partial app function needs access to `var_type_tags` to store actual type tags for applied args. Currently, `createPartialApp` doesn't have access to this information.

**Challenge:** `createPartialApp` is called from `codegenFnCall` when a function is called with fewer args than its arity. At this point, we know:
- `applied_args`: the actual argument values (some may be heap-allocated)
- We need to know the type of each applied arg to store the correct type_tag

**Solution:** Pass `var_type_tags` to `createPartialApp` and use it to look up type tags for applied args.

```zig
fn createPartialApp(
    self: *Codegen,
    fn_name: []const u8,
    fn_val: types.LLVMValueRef,
    total_arity: u32,
    applied_args: []const types.LLVMValueRef,
    applied_arg_names: []const ?[]const u8,  // NEW: names of applied args (for type lookup)
) Error!types.LLVMValueRef {
    // ... existing code ...

    // Store type tags after applied args
    for (0..total_arity) |i| {
        const tag_offset = core.LLVMConstInt(i64_type, 24 + applied_count * 8 + i * 8, 0);
        const tag_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{tag_offset}), 1, "tag_ptr");

        if (i < applied_count) {
            // Applied arg: look up type tag from var_type_tags
            const type_tag = if (self.var_type_tags) |tags|
                if (applied_arg_names[i]) |name| tags.get(name) orelse 0 else 0
            else
                0;
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, @bitCast(type_tag), 0), tag_ptr);
        } else {
            // Unapplied slot: store -1 (skip tag)
            _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, @bitCast(@as(i64, -1)), 0), tag_ptr);
        }
    }
}
```

**Challenge:** We need to track the names of applied args. Currently, `codegenFnCall` doesn't pass this information to `createPartialApp`.

**Alternative Approach:** Instead of tracking names, we can use `expr_type_tags` to look up the type tag of each applied arg expression:

```zig
// In createPartialApp, after storing applied args:
for (applied_args, 0..) |arg, i| {
    // ... existing code to store arg ...

    // Store type tag for this applied arg
    const tag_offset = core.LLVMConstInt(i64_type, 24 + i * 8, 0);
    const tag_ptr = core.LLVMBuildGEP2(self.builder, core.LLVMInt8TypeInContext(self.context), closure_ptr, @constCast(&[_]types.LLVMValueRef{tag_offset}), 1, "tag_ptr");

    // Look up type tag from expr_type_tags (using the original expression)
    const type_tag = if (self.expr_type_tags) |tags|
        tags.get(applied_exprs[i]) orelse 0  // applied_exprs is the original expressions
    else
        0;
    _ = core.LLVMBuildStore(self.builder, core.LLVMConstInt(i64_type, @bitCast(type_tag), 0), tag_ptr);
}
```

But this requires passing the original expressions to `createPartialApp`.

**Simplest Approach:** For now, keep the conservative approach (type_tag=0 for all applied args) but add a comment explaining why. This is safe because:
- type_tag=0 means "int" in the type-based system
- `ko_decref_value` with type_tag=0 and arity=0 does nothing (safe for scalars)
- For heap-allocated applied args, we already call `emitIncref`/`markConsumed` in `createPartialApp`

This means applied heap-allocated args in partial app closures are NOT decreffed when the closure is freed. But they are properly increffed when stored, so the reference count is correct. The only issue is a potential memory leak if the closure is freed before the applied args are used.

**Wait, this is actually correct!** Let me re-read the code...

In `createPartialApp`:
```zig
for (applied_args, 0..) |arg, i| {
    // Inc ref when storing in closure (parent takes shared ownership) -- only for heap-allocated values
    if (self.scope_heap_values.items.len > 0) {
        for (self.scope_heap_values.items) |hv| {
            if (hv == arg) {
                self.emitIncref(arg);
                self.markConsumed(arg);
                break;
            }
        }
    }
    // ... store arg ...
}
```

So:
1. `emitIncref(arg)` increments the ref count (closure takes ownership)
2. `markConsumed(arg)` prevents the original owner from decreffing it
3. When the closure is freed, `ko_decref_closure` should decref the applied args

But currently, `ko_decref_closure` sees type_tag=0 for applied args and thinks they're ints (scalars), so it doesn't decref them. This is a memory leak!

**The fix is to store actual type tags for applied args.** We need to know the type of each applied arg.

#### Step 3: Add Comprehensive Tests

**File:** `src/tests.zig`

Add tests for closure capture decref with different captured types:

```zig
test "runtime: closure capture string decref" {
    try std.testing.expectEqual(@as(i64, 12), try testRuntime(
        \\fn main =
        \\  let s = "hello"
        \\  let f = \x -> String.length s + x
        \\  f 7
    ));
}

test "runtime: closure capture constructor decref" {
    try std.testing.expectEqual(@as(i64, 42), try testRuntime(
        \\type Wrapper = Wrap Int
        \\fn main =
        \\  let w = Wrap 42
        \\  let f = \x ->
        \\    match w
        \\      Wrap v => v + x
        \\  f 0
    ));
}

test "runtime: closure capture tuple decref" {
    try std.testing.expectEqual(@as(i64, 15), try testRuntime(
        \\fn main =
        \\  let t = (3, 4)
        \\  let f = \x ->
        \\    let (a, b) = t
        \\    a + b + x
        \\  f 8
    ));
}

test "runtime: closure capture record decref" {
    try std.testing.expectEqual(@as(i64, 7), try testRuntime(
        \\type Point = { x : Int, y : Int }
        \\fn main =
        \\  let p = Point { x = 3, y = 4 }
        \\  let f = \x -> p.x + p.y + x
        \\  f 0
    ));
}

test "runtime: closure capture arrow decref" {
    try std.testing.expectEqual(@as(i64, 10), try testRuntime(
        \\fn main =
        \\  let g = \x -> x * 2
        \\  let f = \x -> g x + x
        \\  f 5
    ));
}

test "runtime: partial app with heap arg decref" {
    try std.testing.expectEqual(@as(i64, 12), try testRuntime(
        \\fn add x y = x + y
        \\fn main =
        \\  let s = "hello"
        \\  let f = add (String.length s)
        \\  f 7
    ));
}
```

#### Step 4: Update Documentation

**File:** `DESIGN-memory-runtime.md`

Update the closure memory layout documentation to explain:
1. The type_tag system (type-based vs memory-layout)
2. How `ko_decref_closure` uses type tags to determine heap-allocated captures
3. The skip tag (-1) for unapplied partial app slots
4. The `emitIncref`/`markConsumed` pattern for partial app closures

## Implementation Order

1. **Phase 1: Fix `ko_decref_closure` type checks** (Low risk)
   - Update the heap type check to use type-based tags
   - Add skip tag handling
   - Run tests to verify no regressions

2. **Phase 2: Store actual type tags for partial app applied args** (Medium risk)
   - Modify `createPartialApp` to accept type information
   - Update `codegenFnCall` to pass type info to `createPartialApp`
   - Run tests to verify partial app closures work correctly

3. **Phase 3: Add comprehensive tests** (Low risk)
   - Add tests for different captured types
   - Add tests for partial app with heap args
   - Verify memory leaks are fixed

4. **Phase 4: Update documentation** (No risk)
   - Update DESIGN-memory-runtime.md
   - Update AGENTS.md with closure decref patterns

## Risk Assessment

- **Phase 1**: Low risk - only changes the condition for when to decref, not the decref logic itself
- **Phase 2**: Medium risk - changes the closure layout for partial apps, could break existing code
- **Phase 3**: No risk - only adds tests
- **Phase 4**: No risk - only updates documentation

## Success Criteria

1. All 248+ tests pass
2. No memory leaks in closure capture scenarios
3. Partial app closures properly decref applied heap-allocated args
4. Documentation accurately reflects the implementation
