pub const Loc = struct {
    line: usize = 0,
    col: usize = 0,
    end_line: usize = 0,
    end_col: usize = 0,
};

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
    loc: Loc = .{},
};

pub const IfExpr = struct {
    condition: *Expr,
    then_branch: *Expr,
    else_branch: ?*Expr,
    loc: Loc = .{},
};

pub const LetExprExpr = struct {
    name: []const u8,
    type_ann: ?TypeExpr,
    value: *Expr,
    body: *Expr,
    loc: Loc = .{},
    pattern: ?Pattern = null,
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
    cons,
};

pub const UnaryOp = enum {
    neg,
    not,
    ref,
    deref,
    try_op,
};

pub const Expr = union(enum) {
    int_literal: i64,
    float_literal: f64,
    string_literal: []const u8,
    char_literal: []const u8,
    bool_literal: bool,
    identifier: struct { name: []const u8, loc: Loc = .{} },
    constructor: struct { name: []const u8, loc: Loc = .{} },
    record_literal: struct { name: []const u8, fields: []const NamedArg, loc: Loc = .{} },
    tuple: struct { items: []const *Expr, loc: Loc = .{} },
    block: struct { items: []const *Expr, loc: Loc = .{} },
    field_access: struct { object: *Expr, field: []const u8, loc: Loc = .{} },
    fn_call: FnCallExpr,
    lambda: struct { params: []const Pattern, body: *Expr, loc: Loc = .{} },
    comptime_expr: *Expr,
    unary_op: struct { op: UnaryOp, expr: *Expr, loc: Loc = .{} },
    binary_op: struct { op: BinaryOp, left: *Expr, right: *Expr, loc: Loc = .{} },
    let_expr: LetExprExpr,
    if_expr: IfExpr,
    match_expr: struct { value: *Expr, arms: []const MatchArm, loc: Loc = .{} },
    assign_expr: struct { target: *Expr, value: *Expr, loc: Loc = .{} },
    ref_expr: *Expr,
    pat_record: struct { name: []const u8, bindings: []const []const u8, rest: bool, loc: Loc = .{} },

    pub fn getLoc(self: *const Expr) Loc {
        return switch (self.*) {
            .int_literal, .float_literal, .bool_literal, .string_literal, .char_literal => .{},
            .identifier => |id| id.loc,
            .constructor => |c| c.loc,
            .record_literal => |r| r.loc,
            .tuple => |t| t.loc,
            .block => |b| b.loc,
            .field_access => |fa| fa.loc,
            .fn_call => |call| call.loc,
            .lambda => |lam| lam.loc,
            .comptime_expr => |inner| inner.getLoc(),
            .unary_op => |u| u.loc,
            .binary_op => |b| b.loc,
            .let_expr => |l| l.loc,
            .if_expr => |i| i.loc,
            .match_expr => |m| m.loc,
            .assign_expr => |a| a.loc,
            .ref_expr => |inner| inner.getLoc(),
            .pat_record => |r| r.loc,
        };
    }

    pub fn setLoc(self: *Expr, loc: Loc) void {
        switch (self.*) {
            .int_literal, .float_literal, .bool_literal, .string_literal, .char_literal => {},
            .identifier => |*id| id.loc = loc,
            .constructor => |*c| c.loc = loc,
            .record_literal => |*r| r.loc = loc,
            .tuple => |*t| t.loc = loc,
            .block => |*b| b.loc = loc,
            .field_access => |*fa| fa.loc = loc,
            .fn_call => |*call| call.loc = loc,
            .lambda => |*lam| lam.loc = loc,
            .comptime_expr => |inner| inner.setLoc(loc),
            .unary_op => |*u| u.loc = loc,
            .binary_op => |*b| b.loc = loc,
            .let_expr => |*l| l.loc = loc,
            .if_expr => |*i| i.loc = loc,
            .match_expr => |*m| m.loc = loc,
            .assign_expr => |*a| a.loc = loc,
            .ref_expr => |inner| inner.setLoc(loc),
            .pat_record => |*r| r.loc = loc,
        }
    }
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
    doc_comments: ?[]const []const u8 = null,
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
    doc_comments: ?[]const []const u8 = null,
    loc: Loc = .{},
};

pub const LetBinding = struct {
    name: []const u8,
    type_ann: ?TypeExpr,
    value: *Expr,
    is_pub: bool,
    doc_comments: ?[]const []const u8 = null,
    loc: Loc = .{},
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
    doc_comments: ?[]const []const u8 = null,
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
