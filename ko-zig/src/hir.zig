const std = @import("std");
const typecheck = @import("typecheck.zig");

pub const HirId = usize;
pub const LocalVarId = usize;

pub const SourceSpan = struct {
    line: usize = 0,
    col: usize = 0,
    end_line: usize = 0,
    end_col: usize = 0,
};

pub const HirExpr = struct {
    id: HirId,
    ty: *const typecheck.Type,
    span: SourceSpan,
    kind: HirExprKind,
    live: bool = false,
};

pub const HirExprKind = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    char: u8,
    string: []const u8,
    local: LocalVarId,
    global: []const u8,
    lambda: LambdaExpr,
    apply: ApplyExpr,
    let: LetExpr,
    let_rec: LetRecExpr,
    if_: IfExpr,
    match: MatchExpr,
    record: RecordExpr,
    record_access: RecordAccess,
    tuple: TupleExpr,
    constructor: ConstructorExpr,
    ref: HirId,
    deref: HirId,
    assign: AssignExpr,
    comptime_expr: HirId,
    primop: PrimOpExpr,
};

pub const LambdaExpr = struct {
    params: []const LocalVarId,
    body: HirId,
    captures: []const LocalVarId,
};

pub const ApplyExpr = struct {
    func: HirId,
    arg: HirId,
};

pub const LetExpr = struct {
    name: LocalVarId,
    value: HirId,
    body: HirId,
};

pub const LetRecBinding = struct {
    name: LocalVarId,
    value: HirId,
};

pub const LetRecExpr = struct {
    bindings: []const LetRecBinding,
    body: HirId,
};

pub const IfExpr = struct {
    cond: HirId,
    then: HirId,
    else_: HirId,
};

pub const MatchExpr = struct {
    scrutinee: HirId,
    arms: []const MatchArm,
};

pub const RecordExpr = struct {
    fields: []const RecordField,
};

pub const RecordField = struct {
    name: []const u8,
    value: HirId,
};

pub const RecordAccess = struct {
    record: HirId,
    field: []const u8,
};

pub const TupleExpr = struct {
    elements: []const HirId,
};

pub const ConstructorExpr = struct {
    type_name: []const u8,
    ctor_name: []const u8,
    args: []const HirId,
};

pub const AssignExpr = struct {
    target: HirId,
    value: HirId,
};

pub const PrimOpExpr = struct {
    op: PrimOp,
    args: []const HirId,
};

pub const MatchArm = struct {
    pattern: Pattern,
    guard: ?HirId,
    body: HirId,
};

pub const Pattern = union(enum) {
    wildcard: void,
    bind: LocalVarId,
    literal: HirLiteral,
    constructor: ConstructorPattern,
    record: RecordPattern,
    tuple: []const Pattern,
};

pub const ConstructorPattern = struct {
    type_name: []const u8,
    ctor_name: []const u8,
    args: []const Pattern,
};

pub const RecordPattern = struct {
    fields: []const RecordPatternField,
    rest: bool,
};

pub const RecordPatternField = struct {
    name: []const u8,
    p: Pattern,
};

pub const HirLiteral = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    char: []const u8,
    bool: bool,
};

pub const PrimOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    eq,
    neq,
    lt,
    le,
    gt,
    ge,
    and_,
    or_,
    not_,
    concat,
    ptrtoint,
    inttoptr,
    bitcast,
};
