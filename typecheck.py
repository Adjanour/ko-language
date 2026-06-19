"""
Hindley-Milner type inference for Kō.

Uses Algorithm J (mutable type variables with union-find) for efficient unification.
Supports let-polymorphism, ADTs with type parameters, and function types.
"""

from dataclasses import dataclass, field
from typing import Optional, Dict, List, Set, Tuple
from enum import Enum, auto


# ===== Type Representation =====

class TypeVar:
    """Mutable type variable for inference."""
    def __init__(self, id: int, name: str = ""):
        self.id = id
        self.name = name or f"t{id}"
        self.instance: Optional['Type'] = None  # For unification
    
    def __repr__(self):
        if self.instance:
            return repr(self.instance)
        return self.name


class TypeCon:
    """Type constructor (Int, Float, String, Bool, Unit, Char, Maybe, List, etc.)."""
    def __init__(self, name: str, args: Optional[List['Type']] = None):
        self.name = name
        self.args = args or []
    
    def __repr__(self):
        if self.args:
            args_str = ", ".join(repr(a) for a in self.args)
            return f"{self.name}({args_str})"
        return self.name
    
    def __eq__(self, other):
        if not isinstance(other, TypeCon):
            return False
        return self.name == other.name and len(self.args) == len(other.args) and all(a == b for a, b in zip(self.args, other.args))
    
    def __hash__(self):
        return hash((self.name, tuple(repr(a) for a in self.args)))


class TypeArrow:
    """Function type: a -> b"""
    def __init__(self, from_type: 'Type', to_type: 'Type'):
        self.from_type = from_type
        self.to_type = to_type
    
    def __repr__(self):
        from_str = repr(self.from_type)
        if isinstance(self.from_type, TypeArrow):
            from_str = f"({from_str})"
        return f"{from_str} -> {self.to_type}"


# Type can be TypeVar, TypeCon, or TypeArrow
Type = TypeVar | TypeCon | TypeArrow


# ===== Type Schemes (for let-polymorphism) =====

@dataclass
class TypeScheme:
    """Universally quantified type: forall a b. type"""
    quantified: List[TypeVar]
    body: Type
    
    def __repr__(self):
        if self.quantified:
            vars_str = " ".join(v.name for v in self.quantified)
            return f"forall {vars_str}. {self.body}"
        return repr(self.body)


# ===== Type Environment =====

class TypeEnv:
    """Type environment mapping variable names to type schemes."""
    def __init__(self, parent: Optional['TypeEnv'] = None):
        self.bindings: Dict[str, TypeScheme] = {}
        self.parent = parent
    
    def get(self, name: str) -> Optional[TypeScheme]:
        if name in self.bindings:
            return self.bindings[name]
        if self.parent:
            return self.parent.get(name)
        return None
    
    def set(self, name: str, scheme: TypeScheme):
        self.bindings[name] = scheme
    
    def extend(self) -> 'TypeEnv':
        return TypeEnv(parent=self)


# ===== Union-Find =====

def find(t: Type) -> Type:
    """Find the root of a type variable's equivalence class."""
    if isinstance(t, TypeVar):
        if t.instance is not None:
            t.instance = find(t.instance)  # Path compression
            return t.instance
        return t
    return t


def unify(t1: Type, t2: Type, env: TypeEnv) -> Type:
    """Unify two types, returning their common type.
    
    Raises TypeError if types cannot be unified.
    """
    t1 = find(t1)
    t2 = find(t2)
    
    # Same type variable
    if isinstance(t1, TypeVar) and isinstance(t2, TypeVar) and t1.id == t2.id:
        return t1
    
    # Type variable -> instance
    if isinstance(t1, TypeVar):
        if occurs_in(t1, t2):
            raise TypeError(f"Infinite type: {t1.name} occurs in {t2}")
        t1.instance = t2
        return t2
    
    if isinstance(t2, TypeVar):
        if occurs_in(t2, t1):
            raise TypeError(f"Infinite type: {t2.name} occurs in {t1}")
        t2.instance = t1
        return t1
    
    # Function types
    if isinstance(t1, TypeArrow) and isinstance(t2, TypeArrow):
        unify(t1.from_type, t2.from_type, env)
        unify(t1.to_type, t2.to_type, env)
        return t1
    
    # Type constructors
    if isinstance(t1, TypeCon) and isinstance(t2, TypeCon):
        if t1.name != t2.name:
            raise TypeError(f"Type mismatch: {t1.name} vs {t2.name}")
        if len(t1.args) != len(t2.args):
            raise TypeError(f"Arity mismatch for {t1.name}: {len(t1.args)} vs {len(t2.args)}")
        for a, b in zip(t1.args, t2.args):
            unify(a, b, env)
        return t1
    
    raise TypeError(f"Cannot unify {t1} with {t2}")


def occurs_in(var: TypeVar, t: Type) -> bool:
    """Check if a type variable occurs in a type (occurs check)."""
    t = find(t)
    if isinstance(t, TypeVar):
        return var.id == t.id
    if isinstance(t, TypeArrow):
        return occurs_in(var, t.from_type) or occurs_in(var, t.to_type)
    if isinstance(t, TypeCon):
        return any(occurs_in(var, arg) for arg in t.args)
    return False


# ===== Fresh Type Variables =====

_fresh_counter = 0

def fresh_var(name: str = "") -> TypeVar:
    """Create a fresh type variable."""
    global _fresh_counter
    _fresh_counter += 1
    return TypeVar(_fresh_counter, name)


def instantiate(scheme: TypeScheme) -> Type:
    """Instantiate a type scheme with fresh type variables.
    
    Always deep-copies the body, creating fresh vars for all free variables
    (both quantified and non-quantified) to prevent mutation of the scheme.
    """
    # Map ALL free variables in the body to fresh copies
    all_free = get_free_vars(scheme.body)
    var_map = {}
    for fv in all_free:
        var_map[fv.id] = fresh_var(fv.name)
    
    return instantiate_type(scheme.body, var_map)


def instantiate_type(t: Type, var_map: Dict[int, TypeVar]) -> Type:
    """Instantiate a type with a variable mapping."""
    if isinstance(t, TypeVar):
        if t.id in var_map:
            return var_map[t.id]
        return t
    if isinstance(t, TypeArrow):
        return TypeArrow(
            instantiate_type(t.from_type, var_map),
            instantiate_type(t.to_type, var_map)
        )
    if isinstance(t, TypeCon):
        return TypeCon(t.name, [instantiate_type(arg, var_map) for arg in t.args])
    return t


def generalize(env: TypeEnv, t: Type) -> TypeScheme:
    """Generalize a type to a type scheme (quantify free variables)."""
    free_vars = get_free_vars(t)
    env_vars = get_env_vars(env)
    quantified = [v for v in free_vars if v.id not in env_vars]
    return TypeScheme(quantified, t)


def get_free_vars(t: Type) -> List[TypeVar]:
    """Get all free type variables in a type."""
    t = find(t)
    if isinstance(t, TypeVar):
        return [t]
    if isinstance(t, TypeArrow):
        return get_free_vars(t.from_type) + get_free_vars(t.to_type)
    if isinstance(t, TypeCon):
        result = []
        for arg in t.args:
            result.extend(get_free_vars(arg))
        return result
    return []


def get_env_vars(env: TypeEnv) -> Set[int]:
    """Get all type variable IDs in an environment."""
    result = set()
    for scheme in env.bindings.values():
        for v in scheme.quantified:
            result.add(v.id)
        result.update(v.id for v in get_free_vars(scheme.body))
    if env.parent:
        result.update(get_env_vars(env.parent))
    return result


# ===== Built-in Types =====

# Primitive types
TYPE_INT = TypeCon("Int")
TYPE_FLOAT = TypeCon("Float")
TYPE_STRING = TypeCon("String")
TYPE_BOOL = TypeCon("Bool")
TYPE_CHAR = TypeCon("Char")
TYPE_UNIT = TypeCon("Unit")


def type_arrow(from_type: Type, to_type: Type) -> TypeArrow:
    """Create a function type."""
    return TypeArrow(from_type, to_type)


def type_maybe(a: Type) -> TypeCon:
    """Maybe a type."""
    return TypeCon("Maybe", [a])


def type_list(a: Type) -> TypeCon:
    """List a type."""
    return TypeCon("List", [a])


def type_result(e: Type, a: Type) -> TypeCon:
    """Result e a type."""
    return TypeCon("Result", [e, a])


# ===== Type Errors =====

class TypeError(Exception):
    """Type inference error."""
    def __init__(self, message: str, location=None):
        super().__init__(message)
        self.message = message
        self.location = location


# ===== Type Inference =====

class TypeInferer:
    """Hindley-Milner type inference."""
    
    def __init__(self):
        self.env = TypeEnv()
        self.errors: List[TypeError] = []
        self.type_constructors: Dict[str, TypeCon] = {}  # Cache for type constructors
        self._setup_builtins()
    
    def _setup_builtins(self):
        """Set up types for built-in functions."""
        
        # I/O functions (polymorphic)
        a = fresh_var("a")
        self.env.set("print", TypeScheme([a], type_arrow(a, TYPE_UNIT)))
        a = fresh_var("a")
        self.env.set("println", TypeScheme([a], type_arrow(a, TYPE_UNIT)))
        a = fresh_var("a")
        self.env.set("inspect", TypeScheme([a], type_arrow(a, TYPE_UNIT)))
        
        # String operations
        self.env.set("len", TypeScheme([], type_arrow(TYPE_STRING, TYPE_INT)))
        self.env.set("concat", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_STRING))))
        self.env.set("char_at", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_INT, TYPE_CHAR))))
        self.env.set("substring", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_INT, type_arrow(TYPE_INT, TYPE_STRING)))))
        self.env.set("contains", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_BOOL))))
        self.env.set("to_upper", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        self.env.set("to_lower", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        self.env.set("trim", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        self.env.set("starts_with", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_BOOL))))
        self.env.set("ends_with", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_BOOL))))
        self.env.set("repeat", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_INT, TYPE_STRING))))
        self.env.set("split", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_STRING))))  # simplified; real type involves List
        self.env.set("join", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_STRING))))  # simplified
        self.env.set("replace", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_STRING)))))
        self.env.set("panic", TypeScheme([], type_arrow(TYPE_STRING, TYPE_UNIT)))
        self.env.set("ord", TypeScheme([], type_arrow(TYPE_CHAR, TYPE_INT)))
        self.env.set("chr", TypeScheme([], type_arrow(TYPE_INT, TYPE_CHAR)))
        self.env.set("parse_int", TypeScheme([], type_arrow(TYPE_STRING, TYPE_INT)))  # simplified
        self.env.set("parse_float", TypeScheme([], type_arrow(TYPE_STRING, TYPE_FLOAT)))  # simplified
        self.env.set("is_null", TypeScheme([a], type_arrow(a, TYPE_BOOL)))
        self.env.set("file_exists", TypeScheme([], type_arrow(TYPE_STRING, TYPE_BOOL)))
        self.env.set("sleep", TypeScheme([], type_arrow(TYPE_INT, TYPE_UNIT)))
        
        # Math operations
        self.env.set("abs", TypeScheme([], type_arrow(TYPE_INT, TYPE_INT)))
        self.env.set("min", TypeScheme([], type_arrow(TYPE_INT, type_arrow(TYPE_INT, TYPE_INT))))
        self.env.set("max", TypeScheme([], type_arrow(TYPE_INT, type_arrow(TYPE_INT, TYPE_INT))))
        self.env.set("pow", TypeScheme([], type_arrow(TYPE_INT, type_arrow(TYPE_INT, TYPE_INT))))
        self.env.set("sqrt", TypeScheme([], type_arrow(TYPE_FLOAT, TYPE_FLOAT)))
        self.env.set("floor", TypeScheme([], type_arrow(TYPE_FLOAT, TYPE_INT)))
        self.env.set("ceil", TypeScheme([], type_arrow(TYPE_FLOAT, TYPE_INT)))
        self.env.set("mod", TypeScheme([], type_arrow(TYPE_INT, type_arrow(TYPE_INT, TYPE_INT))))
        
        # Type conversion (polymorphic)
        a = fresh_var("a")
        self.env.set("to_string", TypeScheme([a], type_arrow(a, TYPE_STRING)))
        self.env.set("to_int", TypeScheme([], type_arrow(TYPE_STRING, TYPE_INT)))
        a = fresh_var("a")
        self.env.set("to_float", TypeScheme([a], type_arrow(a, TYPE_FLOAT)))
        a = fresh_var("a")
        self.env.set("type_of", TypeScheme([a], type_arrow(a, TYPE_STRING)))
        a = fresh_var("a")
        self.env.set("is_int", TypeScheme([a], type_arrow(a, TYPE_BOOL)))
        a = fresh_var("a")
        self.env.set("is_float", TypeScheme([a], type_arrow(a, TYPE_BOOL)))
        a = fresh_var("a")
        self.env.set("is_string", TypeScheme([a], type_arrow(a, TYPE_BOOL)))
        a = fresh_var("a")
        self.env.set("is_bool", TypeScheme([a], type_arrow(a, TYPE_BOOL)))
        
        # I/O (returns values)
        self.env.set("run", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        self.env.set("read_file", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        self.env.set("write_file", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_UNIT))))
        self.env.set("append_file", TypeScheme([], type_arrow(TYPE_STRING, type_arrow(TYPE_STRING, TYPE_UNIT))))
        self.env.set("read_line", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        self.env.set("get_env", TypeScheme([], type_arrow(TYPE_STRING, TYPE_STRING)))
        
        # System
        self.env.set("exit", TypeScheme([], type_arrow(TYPE_INT, TYPE_UNIT)))
        self.env.set("args_count", TypeScheme([], TYPE_INT))
        self.env.set("args_get", TypeScheme([], type_arrow(TYPE_INT, TYPE_STRING)))
        self.env.set("now", TypeScheme([], TYPE_INT))
        
        # Random
        self.env.set("random", TypeScheme([], type_arrow(TYPE_INT, type_arrow(TYPE_INT, type_arrow(TYPE_INT, TYPE_INT)))))
        self.env.set("seed", TypeScheme([], TYPE_INT))
        
        # Test framework
        self.env.set("assert", TypeScheme([], type_arrow(TYPE_BOOL, TYPE_UNIT)))
        a = fresh_var("a")
        self.env.set("assert_eq", TypeScheme([a], type_arrow(a, type_arrow(a, TYPE_UNIT))))
        a = fresh_var("a")
        self.env.set("test", TypeScheme([a], type_arrow(TYPE_STRING, type_arrow(a, TYPE_UNIT))))
        self.env.set("run_tests", TypeScheme([], TYPE_UNIT))
        
        # Ref cells (simplified for now)
        a = fresh_var("a")
        self.env.set("ref", TypeScheme([a], type_arrow(a, a)))
        a = fresh_var("a")
        self.env.set("deref", TypeScheme([a], type_arrow(a, a)))
        a = fresh_var("a")
        self.env.set("set", TypeScheme([a], type_arrow(a, type_arrow(a, TYPE_UNIT))))

        # List constructors (kept as builtins for list literal desugaring)
        a = fresh_var("a")
        self.env.set("Nil", TypeScheme([a], type_list(a)))
        a = fresh_var("a")
        self.env.set("Cons", TypeScheme([a], type_arrow(a, type_arrow(type_list(a), type_list(a)))))
    
    def infer(self, program) -> Dict[str, TypeScheme]:
        """Infer types for a program, returning a mapping of names to types."""
        from parser import Program, FnDef, LetExpr, Block, IfExpr, MatchExpr, FnCall, Identifier, IntLiteral, FloatLiteral, StringLiteral, BoolLiteral, CharLiteral, BinaryOp, UnaryOp, Lambda, RefExpr, DerefExpr, SetExpr, TypeDef
        
        # First pass: register type definitions
        for defn in program.definitions:
            if isinstance(defn, TypeDef):
                self._register_type(defn)
        
        # Second pass: infer function types
        for defn in program.definitions:
            if isinstance(defn, FnDef):
                try:
                    self._infer_fn(defn)
                except TypeError as e:
                    self.errors.append(e)
        
        return dict(self.env.bindings)
    
    def _register_type(self, typedef: 'TypeDef'):
        """Register a type definition and its constructors."""
        from parser import TypeDef

        # Create fresh type variables for type parameters
        param_vars = []
        for p in typedef.type_params:
            v = fresh_var(p)
            param_vars.append(v)

        # Build the type constructor with params: e.g. Maybe(a)
        if param_vars:
            type_con = TypeCon(typedef.name, param_vars)
        else:
            if typedef.name not in self.type_constructors:
                self.type_constructors[typedef.name] = TypeCon(typedef.name)
            type_con = self.type_constructors[typedef.name]

        # Register each constructor
        for ctor in typedef.constructors:
            ctor_type = type_con

            # Resolve field types in reverse to build arrow type
            for i, ft in enumerate(reversed(ctor.field_types)):
                resolved = self._resolve_field_type(ft, typedef.type_params, param_vars)
                ctor_type = type_arrow(resolved, ctor_type)

            # Generalize over type parameters
            scheme = generalize(self.env, ctor_type)
            self.env.set(ctor.name, scheme)

        # Store bare type constructor for later use
        self.type_constructors[typedef.name] = TypeCon(typedef.name)

    def _resolve_field_type(self, field_type, type_params, param_vars):
        """Resolve a field type from AST to a Type."""
        if field_type == "_":
            # Wildcard → fresh type variable
            return fresh_var("t")
        if field_type in type_params:
            # Type parameter reference → use the corresponding TypeVar
            idx = type_params.index(field_type)
            return param_vars[idx]
        # Could be a concrete type name (Int, String, etc.)
        return TypeCon(field_type)
    
    def _infer_fn(self, fn: 'FnDef'):
        """Infer type for a function definition."""
        from parser import FnDef
        
        # Create fresh type variables for parameters
        param_types = []
        for p in fn.params:
            pt = fresh_var(p)
            param_types.append(pt)
            self.env.set(p, TypeScheme([], pt))
        
        # Add function to environment with fresh type (for recursion)
        fn_ret_type = fresh_var(f"{fn.name}_ret")
        fn_type = fn_ret_type
        for pt in reversed(param_types):
            fn_type = type_arrow(pt, fn_type)
        self.env.set(fn.name, TypeScheme([], fn_type))
        
        # Infer return type
        body_type = self._infer_expr(fn.body)
        
        # Unify return type with body type
        unify(fn_ret_type, body_type, self.env)
        
        # Get the final type
        final_type = find(fn_type)
        
        # Generalize
        scheme = generalize(self.env, final_type)
        self.env.set(fn.name, scheme)
    
    def _infer_expr(self, expr) -> Type:
        """Infer type for an expression."""
        from parser import FnDef, LetExpr, Block, IfExpr, MatchExpr, FnCall, Identifier, IntLiteral, FloatLiteral, StringLiteral, BoolLiteral, CharLiteral, BinaryOp, UnaryOp, Lambda, RefExpr, DerefExpr, SetExpr
        
        if isinstance(expr, IntLiteral):
            return TYPE_INT
        
        if isinstance(expr, FloatLiteral):
            return TYPE_FLOAT
        
        if isinstance(expr, StringLiteral):
            return TYPE_STRING
        
        if isinstance(expr, BoolLiteral):
            return TYPE_BOOL
        
        if isinstance(expr, CharLiteral):
            return TYPE_CHAR
        
        if isinstance(expr, Identifier):
            scheme = self.env.get(expr.name)
            if scheme is None:
                raise TypeError(f"Undefined variable: {expr.name}", expr.loc)
            return instantiate(scheme)
        
        if isinstance(expr, BinaryOp):
            left_type = self._infer_expr(expr.left)
            right_type = self._infer_expr(expr.right)
            
            # Arithmetic operators
            if expr.op in ['+', '-', '*', '/']:
                unify(left_type, TYPE_INT, self.env)
                unify(right_type, TYPE_INT, self.env)
                return TYPE_INT
            
            # Float arithmetic
            if expr.op in ['+.', '-.', '*.', '/.']:
                unify(left_type, TYPE_FLOAT, self.env)
                unify(right_type, TYPE_FLOAT, self.env)
                return TYPE_FLOAT
            
            # Comparison
            if expr.op in ['<', '>', '<=', '>=']:
                unify(left_type, TYPE_INT, self.env)
                unify(right_type, TYPE_INT, self.env)
                return TYPE_BOOL
            
            # Equality
            if expr.op in ['==', '!=']:
                unify(left_type, right_type, self.env)
                return TYPE_BOOL
            
            # String concatenation
            if expr.op == '++':
                unify(left_type, TYPE_STRING, self.env)
                unify(right_type, TYPE_STRING, self.env)
                return TYPE_STRING
            
            # Boolean operators
            if expr.op in ['&&', '||', 'and', 'or']:
                unify(left_type, TYPE_BOOL, self.env)
                unify(right_type, TYPE_BOOL, self.env)
                return TYPE_BOOL
        
        if isinstance(expr, UnaryOp):
            operand_type = self._infer_expr(expr.expr)
            
            if expr.op == '-':
                unify(operand_type, TYPE_INT, self.env)
                return TYPE_INT
            if expr.op == '-.':
                unify(operand_type, TYPE_FLOAT, self.env)
                return TYPE_FLOAT
            if expr.op == 'not':
                unify(operand_type, TYPE_BOOL, self.env)
                return TYPE_BOOL
        
        if isinstance(expr, Block):
            result_type = None
            for e in expr.exprs:
                result_type = self._infer_expr(e)
            return result_type or TYPE_UNIT
        
        if isinstance(expr, LetExpr):
            val_type = self._infer_expr(expr.value)
            scheme = generalize(self.env, val_type)
            self.env.set(expr.name, scheme)
            return self._infer_expr(expr.body)
        
        if isinstance(expr, IfExpr):
            cond_type = self._infer_expr(expr.cond)
            unify(cond_type, TYPE_BOOL, self.env)
            then_type = self._infer_expr(expr.then_branch)
            if expr.else_branch:
                else_type = self._infer_expr(expr.else_branch)
                unify(then_type, else_type, self.env)
                return then_type
            return then_type
        
        if isinstance(expr, MatchExpr):
            # Infer type of matched value
            value_type = self._infer_expr(expr.value)
            
            # Infer type of first arm
            result_type = None
            for i, arm in enumerate(expr.arms):
                # Bind pattern variables
                for name, pat_type in self._extract_pattern_types(arm.pattern, value_type):
                    self.env.set(name, TypeScheme([], pat_type))
                
                arm_type = self._infer_expr(arm.body)
                if i == 0:
                    result_type = arm_type
                else:
                    unify(result_type, arm_type, self.env)
            
            return result_type or TYPE_UNIT
        
        if isinstance(expr, FnCall):
            fn_type = self._infer_expr(expr.func)
            arg_types = [self._infer_expr(a) for a in expr.args]
            
            # Build expected function type
            result_type = fresh_var("ret")
            expected_type = result_type
            for at in reversed(arg_types):
                expected_type = type_arrow(at, expected_type)
            
            unify(fn_type, expected_type, self.env)
            return result_type
        
        if isinstance(expr, Lambda):
            param_types = [fresh_var(p) for p in expr.params]
            for p, pt in zip(expr.params, param_types):
                self.env.set(p, TypeScheme([], pt))
            
            body_type = self._infer_expr(expr.body)
            
            fn_type = body_type
            for pt in reversed(param_types):
                fn_type = type_arrow(pt, fn_type)
            
            return fn_type
        
        if isinstance(expr, Identifier):
            # Check if it's a constructor
            scheme = self.env.get(expr.name)
            if scheme is None:
                raise TypeError(f"Undefined variable: {expr.name}", expr.loc)
            return instantiate(scheme)
        
        if isinstance(expr, RefExpr):
            val_type = self._infer_expr(expr.value)
            return val_type  # Simplified
        
        if isinstance(expr, DerefExpr):
            val_type = self._infer_expr(expr.value)
            return val_type  # Simplified
        
        if isinstance(expr, SetExpr):
            val_type = self._infer_expr(expr.value)
            return TYPE_UNIT
        
        # Default
        return TYPE_UNIT
    
    def _extract_pattern_types(self, pattern, expected_type: Type) -> List[Tuple[str, Type]]:
        """Extract type bindings from a pattern."""
        from parser import PatWildcard, PatLiteral, PatConstructor, PatIdent
        
        if isinstance(pattern, PatWildcard):
            return []
        
        if isinstance(pattern, PatLiteral):
            if isinstance(pattern.value, int):
                unify(expected_type, TYPE_INT, self.env)
            elif isinstance(pattern.value, float):
                unify(expected_type, TYPE_FLOAT, self.env)
            elif isinstance(pattern.value, str):
                unify(expected_type, TYPE_STRING, self.env)
            elif isinstance(pattern.value, bool):
                unify(expected_type, TYPE_BOOL, self.env)
            return []
        
        if isinstance(pattern, PatConstructor):
            # Get constructor type
            scheme = self.env.get(pattern.name)
            if scheme is None:
                raise TypeError(f"Unknown constructor: {pattern.name}")
            
            ctor_type = instantiate(scheme)
            
            # The constructor type is: arg0 -> arg1 -> ... -> ADT_type
            # We need to peel off arrow types and match with sub-patterns
            bindings = []
            current_type = ctor_type
            for sub_pattern in pattern.args:
                if isinstance(current_type, TypeArrow):
                    # Unify the field type with the sub-pattern
                    bindings.extend(self._extract_pattern_types(sub_pattern, current_type.from_type))
                    current_type = current_type.to_type
                else:
                    # Shouldn't happen, but handle gracefully
                    arg_type = fresh_var("arg")
                    bindings.extend(self._extract_pattern_types(sub_pattern, arg_type))
            
            # Unify the remaining type (ADT type) with expected_type
            unify(current_type, expected_type, self.env)
            
            return bindings
        
        if isinstance(pattern, PatIdent):
            return [(pattern.name, expected_type)]
        
        return []
