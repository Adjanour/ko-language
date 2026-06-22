pub const Literal = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    char: []const u8,
    bool: bool,
};

pub const TypeExpr = union(enum) {
    ident: []const u8,
    constructor: []const u8,
    arrow: struct { from: *TypeExpr, to: *TypeExpr },
    record: []const RecordField,
    group: *TypeExpr,
    application: struct { func: *TypeExpr, arg: *TypeExpr },
};

pub const Pattern = union(enum) {
    wildcard,
    identifier: []const u8,
    constructor: struct { name: []const u8, args: []const Pattern },
    record: struct { name: []const u8, fields: []const RecordPatternField, rest: bool },
    literal: Literal,
    tuple: []const Pattern,
};

pub const RecordPatternField = struct {
    name: []const u8,
    pattern: ?*Pattern,
};

pub const NamedArg = struct {
    name: []const u8,
    value: *Expr,
};

pub const FnCallExpr = struct {
    func: *Expr,
    args: []const *Expr,
    named_args: []const NamedArg,
};

pub const IfExpr = struct {
    condition: *Expr,
    then_branch: *Expr,
    else_branch: ?*Expr,
};

pub const LetExprExpr = struct {
    name: []const u8,
    type_ann: ?TypeExpr,
    value: *Expr,
    body: *Expr,
};

pub const MatchArm = struct {
    pattern: Pattern,
    body: *Expr,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    and_op,
    or_op,
    pipe,
};

pub const UnaryOp = enum {
    neg,
    not,
    ref,
    deref,
};

pub const Expr = union(enum) {
    int_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    char_literal: []const u8,
    bool_literal: bool,
    identifier: []const u8,
    constructor: []const u8,
    record_literal: struct { name: []const u8, fields: []const NamedArg },
    tuple: []const *Expr,
    block: []const *Expr,
    field_access: struct { object: *Expr, field: []const u8 },
    fn_call: FnCallExpr,
    lambda: struct { params: []const Pattern, body: *Expr },
    comptime_expr: *Expr,
    unary_op: struct { op: UnaryOp, expr: *Expr },
    binary_op: struct { op: BinaryOp, left: *Expr, right: *Expr },
    let_expr: LetExprExpr,
    if_expr: IfExpr,
    match_expr: struct { value: *Expr, arms: []const MatchArm },
    assign_expr: struct { target: *Expr, value: *Expr },
    ref_expr: *Expr,
    pat_record: struct { name: []const u8, bindings: []const []const u8, rest: bool },
};

pub const Constructor = struct {
    name: []const u8,
    params: []const TypeExpr,
};

pub const RecordField = struct {
    name: []const u8,
    type_expr: TypeExpr,
};

pub const TypeDef = struct {
    name: []const u8,
    type_params: []const []const u8,
    body: union(enum) {
        sum: []const Constructor,
        record: []const RecordField,
    },
    is_pub: bool,
};

pub const FnParam = struct {
    pattern: Pattern,
    type_ann: ?TypeExpr,
};

pub const FnDef = struct {
    name: []const u8,
    params: []const FnParam,
    return_type: ?TypeExpr,
    body: *Expr,
    is_pub: bool,
    is_comptime: bool,
};

pub const LetBinding = struct {
    name: []const u8,
    type_ann: ?TypeExpr,
    value: *Expr,
    is_pub: bool,
};

pub const Import = struct {
    path: []const []const u8,
    selective: ?[]const []const u8,
    alias: ?[]const u8,
};

pub const Package = struct {
    name: []const []const u8,
};

pub const ModuleDef = struct {
    name: []const u8,
    definitions: []const Definition,
    is_pub: bool,
};

pub const Definition = union(enum) {
    fn_def: FnDef,
    type_def: TypeDef,
    let_binding: LetBinding,
    import: Import,
    package: Package,
    module_def: ModuleDef,
};

pub const Program = struct {
    imports: []const Import,
    definitions: []const Definition,
    package: ?[]const []const u8,
};
