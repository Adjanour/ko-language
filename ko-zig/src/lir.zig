const std = @import("std");
const hir = @import("hir.zig");

pub const LocalId = usize;
pub const BlockId = usize;

pub const LirFn = struct {
    name: []const u8,
    params: []const LocalId,
    return_type: LirType,
    blocks: []const BasicBlock,
    locals: []const LirType,
};

pub const BasicBlock = struct {
    id: BlockId,
    params: []const LocalId,
    body: []const LirStmt,
    terminator: LirTerminator,
};

pub const LirStmt = union(enum) {
    assign: AssignStmt,
    store: StoreStmt,
    /// Evaluate a value purely for its side effect (e.g. `decref`),
    /// discarding any result. Keeps `assign` destinations meaningful.
    effect: LirValue,
};

pub const AssignStmt = struct {
    dest: LocalId,
    value: LirValue,
    span: ?hir.SourceSpan = null,
};

pub const StoreStmt = struct {
    dest: LocalId,
    value: LocalId,
};

pub const LirValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    char: u8,
    string: StringConst,
    local: LocalId,
    /// Reference to a top-level function by name. Materializes the function
    /// as a value so it can be called directly or stored in a closure.
    fn_ref: []const u8,
    /// Heap allocation with type tag: alloc(type, type_tag)
    /// type_tag: 0=raw, 1=constructor, 2=tuple, 3=record
    alloc: AllocValue,
    load: LocalId,
    alloc_stack: LirType,
    incref: LocalId,
    decref: LocalId,
    is_unique: LocalId,
    call: CallValue,
    make_closure: MakeClosure,
    extract_value: ExtractValue,
    insert_value: InsertValue,
    get_element_ptr: GetElementPtr,
    ptrtoint: LocalId,
    inttoptr: IntToPtr,
    /// Zero-extend, truncate, or bitcast a value to a target type.
    /// Used for boxing/unboxing fields to/from the i64 constructor layout
    /// and for coercions at runtime-function boundaries.
    zext: Convert,
    trunc: Convert,
    bitcast: Convert,
    primop: PrimOpValue,
};

pub const Convert = struct {
    val: LocalId,
    ty: LirType,
};

pub const StringConst = struct {
    ptr: []const u8,
    len: usize,
};

pub const CallValue = struct {
    func: LocalId,
    args: []const LocalId,
    fn_type: LirFnType,
};

pub const MakeClosure = struct {
    fn_name: []const u8,
    captures: []const LocalId,
};

pub const ExtractValue = struct {
    aggregate: LocalId,
    index: usize,
    ty: LirType,
};

pub const InsertValue = struct {
    aggregate: LocalId,
    index: usize,
    value: LocalId,
    ty: LirType,
};

pub const AllocValue = struct {
    ty: LirType,
    /// Type tag: 0=raw, 1=constructor, 2=tuple, 3=record
    type_tag: i64 = 0,
    /// Payload slot count for constructor boxes (type_tag=1); stored in the
    /// box header at offset -16, mirroring the legacy codegen contract. The
    /// runtime `inspect` uses it to tell list cells (arity 2) apart from other
    /// constructor boxes without reading past the box. 0 for non-constructor
    /// allocs, which never write the header.
    arity: u32 = 0,
};

pub const GetElementPtr = struct {
    ptr: LocalId,
    indices: []const LocalId,
    elem_type: LirType,
};

pub const IntToPtr = struct {
    val: LocalId,
    ty: LirType,
};

pub const PrimOpValue = struct {
    op: hir.PrimOp,
    args: []const LocalId,
};

pub const LirTerminator = union(enum) {
    br: BrTarget,
    cond_br: CondBr,
    switch_: SwitchTerminator,
    ret: LocalId,
    unreachable_: void,
    tail_call: CallValue,
};

/// A branch to a basic block, passing arguments for the block's parameters
/// (SSA via block arguments, MLIR-style). `args` binds positionally to
/// `BasicBlock.params`; its length must match the parameter count.
pub const BrTarget = struct {
    target: BlockId,
    args: []const LocalId = &.{},
};

pub const CondBr = struct {
    cond: LocalId,
    then: BrTarget,
    else_: BrTarget,
};

pub const SwitchCase = struct {
    tag: i64,
    target: BrTarget,
};

pub const SwitchTerminator = struct {
    val: LocalId,
    cases: []const SwitchCase,
    default: BrTarget,
};

pub const LirType = union(enum) {
    int: void,
    float: void,
    bool: void,
    char: void,
    string: void,
    unit: void,
    ptr: *const LirType,
    struct_: []const LirType,
    array: ArrayType,
    function: *const LirFnType,
    opaque_type: void,
};

pub const ArrayType = struct {
    elem: *const LirType,
    len: usize,
};

pub const LirFnType = struct {
    params: []const LirType,
    returns: LirType,
};
