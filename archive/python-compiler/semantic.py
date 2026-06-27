"""Kō Semantic Analysis - Exhaustive pattern matching, name resolution, etc."""

from typing import List, Dict, Set, Optional, Tuple
from dataclasses import dataclass, field
from errors import ErrorBundle, SourceLocation
from parser import (
    Program, FnDef, LetBinding, TypeDef, TypeConstructor,
    MatchExpr, MatchArm, PatConstructor, PatIdent, PatWildcard, PatLiteral,
    Expr, Block, LetExpr, IfExpr, Lambda, FnCall, BinaryOp, UnaryOp,
    Identifier, IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral, Wildcard,
)


@dataclass
class ADTInfo:
    """Information about an ADT type."""
    name: str
    type_params: List[str]
    constructors: List[Tuple[str, int]]  # (name, field_count)
    location: Optional[SourceLocation] = None


class SemanticAnalyzer:
    """Performs semantic analysis on the AST."""
    
    def __init__(self, file: str = "<input>"):
        self.file = file
        self.adts: Dict[str, ADTInfo] = {}
        self.errors = ErrorBundle(filename=file)
    
    def analyze(self, program: Program, source_lines: List[str] = None) -> bool:
        """Analyze the program. Returns True if no errors."""
        self.errors.source_lines = source_lines
        
        # First pass: collect all ADT definitions
        for defn in program.definitions:
            if isinstance(defn, TypeDef):
                self._register_adt(defn)
        
        # Second pass: check match exhaustiveness
        self._check_program(program)
        
        return not self.errors.has_errors
    
    def _register_adt(self, typedef: TypeDef):
        """Register an ADT type and its constructors."""
        constructors = [(c.name, c.fields) for c in typedef.constructors]
        self.adts[typedef.name] = ADTInfo(
            name=typedef.name,
            type_params=typedef.type_params,
            constructors=constructors,
            location=typedef.loc
        )
    
    def _check_program(self, program: Program):
        """Check all expressions in the program."""
        for defn in program.definitions:
            if isinstance(defn, FnDef):
                self._check_expr(defn.body)
            elif isinstance(defn, LetBinding):
                self._check_expr(defn.value)
    
    def _check_expr(self, expr: Expr):
        """Recursively check expressions for exhaustiveness."""
        if isinstance(expr, MatchExpr):
            self._check_match(expr)
        elif isinstance(expr, Block):
            for e in expr.exprs:
                self._check_expr(e)
        elif isinstance(expr, LetExpr):
            self._check_expr(expr.value)
            if expr.body is not None:
                self._check_expr(expr.body)
        elif isinstance(expr, IfExpr):
            self._check_expr(expr.cond)
            self._check_expr(expr.then_branch)
            if expr.else_branch:
                self._check_expr(expr.else_branch)
        elif isinstance(expr, Lambda):
            self._check_expr(expr.body)
        elif isinstance(expr, FnCall):
            self._check_expr(expr.func)
            for arg in expr.args:
                self._check_expr(arg)
        elif isinstance(expr, BinaryOp):
            self._check_expr(expr.left)
            self._check_expr(expr.right)
        elif isinstance(expr, UnaryOp):
            self._check_expr(expr.expr)
    
    def _check_match(self, match_expr: MatchExpr):
        """Check if a match expression is exhaustive."""
        # Try to determine the type being matched
        matched_type = self._infer_match_type(match_expr)
        if matched_type is None:
            return  # Can't determine type, skip check
        
        adt_info = self.adts.get(matched_type)
        if adt_info is None:
            return  # Not an ADT, skip check
        
        # Check if there's a wildcard arm (catches everything)
        has_wildcard = any(
            isinstance(arm.pattern, PatWildcard) or isinstance(arm.pattern, PatIdent)
            for arm in match_expr.arms
        )
        
        if has_wildcard:
            return  # Wildcard covers all cases
        
        # Collect covered constructors
        covered = set()
        for arm in match_expr.arms:
            if isinstance(arm.pattern, PatConstructor):
                covered.add(arm.pattern.name)
        
        # Find missing constructors
        all_constructors = {name for name, _ in adt_info.constructors}
        missing = all_constructors - covered
        
        if missing:
            # Build error message
            missing_str = ", ".join(sorted(missing))
            notes = [f"missing constructors: {missing_str}"]
            
            # Add note about where the type was declared
            if adt_info.location:
                notes.append(f"type '{matched_type}' declared here")
            
            self.errors.error(
                f"non-exhaustive pattern match on '{matched_type}'",
                match_expr.loc,
                notes
            )
    
    def _infer_match_type(self, match_expr: MatchExpr) -> Optional[str]:
        """Try to infer the type being matched from patterns."""
        # First, try to infer from the matched expression
        expr_type = self._infer_expr_type(match_expr.value)
        if expr_type:
            return expr_type
        
        # If that fails, try to infer from the patterns
        for arm in match_expr.arms:
            if isinstance(arm.pattern, PatConstructor):
                # Found a constructor pattern - find which ADT it belongs to
                for adt_name, adt_info in self.adts.items():
                    for cons_name, _ in adt_info.constructors:
                        if arm.pattern.name == cons_name:
                            return adt_name
        
        return None
    
    def _infer_expr_type(self, expr: Expr) -> Optional[str]:
        """Try to infer the type of an expression."""
        if isinstance(expr, Identifier):
            # Check if this is a known constructor
            for adt_name, adt_info in self.adts.items():
                for cons_name, _ in adt_info.constructors:
                    if expr.name == cons_name:
                        return adt_name
            return None

        if isinstance(expr, MatchExpr):
            inferred = self._infer_match_type(expr)
            if inferred is not None:
                return inferred

        if isinstance(expr, FnCall) and isinstance(expr.func, Identifier):
            for adt_name, adt_info in self.adts.items():
                for cons_name, arity in adt_info.constructors:
                    if expr.func.name == cons_name and arity == len(expr.args):
                        return adt_name

        # TODO: More sophisticated type inference
        return None


def check_exhaustiveness(program: Program, source_lines: List[str] = None, file: str = "<input>") -> ErrorBundle:
    """Check exhaustiveness of pattern matches in the program."""
    analyzer = SemanticAnalyzer(file)
    analyzer.analyze(program, source_lines)
    return analyzer.errors
