"""Kō Error Reporting - Structured error messages with source context"""

from dataclasses import dataclass
from typing import List, Optional, Tuple
from enum import Enum, auto


class Severity(Enum):
    ERROR = auto()
    WARNING = auto()
    NOTE = auto()


@dataclass
class SourceLocation:
    file: str
    line: int
    col: int
    span_start: int = 0  # byte offset in source
    span_end: int = 0    # byte offset in source


@dataclass
class Diagnostic:
    severity: Severity
    message: str
    location: Optional[SourceLocation]
    notes: List[str] = None
    
    def __post_init__(self):
        if self.notes is None:
            self.notes = []


@dataclass
class ErrorBundle:
    diagnostics: List[Diagnostic] = None
    source_lines: List[str] = None
    filename: str = "<input>"
    
    def __post_init__(self):
        if self.diagnostics is None:
            self.diagnostics = []
    
    def error(self, message: str, location: Optional[SourceLocation] = None, notes: List[str] = None):
        self.diagnostics.append(Diagnostic(Severity.ERROR, message, location, notes or []))
    
    def warning(self, message: str, location: Optional[SourceLocation] = None, notes: List[str] = None):
        self.diagnostics.append(Diagnostic(Severity.WARNING, message, location, notes or []))
    
    def note(self, message: str, location: Optional[SourceLocation] = None):
        self.diagnostics.append(Diagnostic(Severity.NOTE, message, location))
    
    @property
    def has_errors(self) -> bool:
        return any(d.severity == Severity.ERROR for d in self.diagnostics)
    
    @property
    def error_count(self) -> int:
        return sum(1 for d in self.diagnostics if d.severity == Severity.ERROR)
    
    def render(self) -> str:
        """Render all diagnostics as a formatted string."""
        lines = []
        for diag in self.diagnostics:
            lines.append(self._render_diagnostic(diag))
        return "\n\n".join(lines)
    
    def _render_diagnostic(self, diag: Diagnostic) -> str:
        """Render a single diagnostic with source context."""
        parts = []
        
        # Header line: file:line:col: severity: message
        if diag.location:
            loc = diag.location
            header = f"{loc.file}:{loc.line}:{loc.col}: {diag.severity.name.lower()}: {diag.message}"
        else:
            header = f"{diag.severity.name.lower()}: {diag.message}"
        parts.append(header)
        
        # Source context with caret underline
        if diag.location and self.source_lines:
            loc = diag.location
            if 0 < loc.line <= len(self.source_lines):
                source_line = self.source_lines[loc.line - 1]
                parts.append(f"  {loc.line} | {source_line}")
                
                # Calculate underline
                # Show context around the error
                if loc.span_start and loc.span_end:
                    # Use span for precise underline
                    col_start = loc.col - 1
                    span_len = loc.span_end - loc.span_start
                    if span_len > 0:
                        underline = " " * col_start + "^" + "~" * (span_len - 1)
                    else:
                        underline = " " * col_start + "^"
                else:
                    # Just underline the column
                    underline = " " * (loc.col - 1) + "^"
                parts.append(f"       {underline}")
        
        # Notes
        for note in diag.notes:
            parts.append(f"  note: {note}")
        
        # Notes with locations
        for note_diag in self.diagnostics:
            if note_diag.severity == Severity.NOTE and note_diag.location and note_diag != diag:
                if note_diag.location.file == diag.location.file if diag.location else True:
                    loc = note_diag.location
                    parts.append(f"  note: {note_diag.message}")
                    if self.source_lines and 0 < loc.line <= len(self.source_lines):
                        source_line = self.source_lines[loc.line - 1]
                        parts.append(f"    {loc.line} | {source_line}")
                        underline = " " * (loc.col - 1) + "^"
                        parts.append(f"         {underline}")
        
        return "\n".join(parts)


class KōError(Exception):
    """Base exception for Kō compiler errors."""
    def __init__(self, message: str, location: Optional[SourceLocation] = None):
        self.message = message
        self.location = location
        super().__init__(message)


class ParseError(KōError):
    """Parse error."""
    pass


class CompileError(KōError):
    """Compile/codegen error."""
    pass


class SemanticError(KōError):
    """Semantic analysis error (type errors, exhaustiveness, etc.)."""
    pass
