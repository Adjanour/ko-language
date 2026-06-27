#!/usr/bin/env python3
"""
Kō Language Server Protocol (LSP) server — production standard.
Features: diagnostics, hover, go-to-definition, completions, document symbols,
          signature help, find references, workspace symbols, semantic analysis.
"""

import os
import sys
import json
import re
import traceback
from typing import Dict, List, Optional, Any, Tuple
from pathlib import Path
from urllib.parse import urlparse, unquote

sys.path.insert(0, str(Path(__file__).parent))
from lexer import tokenize, Token
from parser import (
    parse, Program, FnDef, TypeDef, LetBinding, LetExpr, Identifier,
    MatchExpr, Import, Block, IfExpr, Lambda, FnCall, BinaryOp, UnaryOp,
    MatchArm, PatConstructor, PatIdent, PatWildcard, PatLiteral,
    Expr, IntLiteral, FloatLiteral, StringLiteral, CharLiteral, BoolLiteral,
)
from typecheck import TypeInferer, TypeError as KoTypeError
from semantic import check_exhaustiveness
from errors import ErrorBundle


class LSPServer:
    def __init__(self):
        self.documents: Dict[str, str] = {}
        self.type_cache: Dict[str, Dict] = {}
        # name -> [{uri, range, is_definition}]
        self.symbol_table: Dict[str, List[Dict]] = {}
        # Flat list for workspace/symbol queries
        self.workspace_symbols: List[Dict] = []
        self.initialized = False
        self._shutdown_requested = False

    def run(self):
        while True:
            try:
                header = self._read_header()
                if header is None:
                    break
                content_length = header.get('Content-Length', 0)
                if content_length == 0:
                    continue
                body = self._read_body(content_length)
                msg = json.loads(body)
                self._dispatch(msg)
            except EOFError:
                break
            except Exception as e:
                self._log(f"Error: {e}")
                traceback.print_exc(file=sys.stderr)

    def _read_header(self) -> Optional[Dict]:
        header = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            line = line.decode('utf-8').strip()
            if line == '':
                break
            if ':' in line:
                key, val = line.split(':', 1)
                header[key.strip()] = int(val.strip())
        return header

    def _read_body(self, length: int) -> str:
        body = b''
        while len(body) < length:
            chunk = sys.stdin.buffer.read(length - len(body))
            if not chunk:
                raise EOFError
            body += chunk
        return body.decode('utf-8')

    def _write(self, msg: dict):
        body = json.dumps(msg)
        content = f"Content-Length: {len(body.encode('utf-8'))}\r\n\r\n{body}"
        sys.stdout.buffer.write(content.encode('utf-8'))
        sys.stdout.buffer.flush()

    def _dispatch(self, msg: dict):
        method = msg.get('method', '')
        msg_id = msg.get('id')
        params = msg.get('params', {})

        if self._shutdown_requested and method != 'exit':
            return

        if method == 'initialize':
            self._handle_initialize(msg_id, params)
        elif method == 'initialized':
            self.initialized = True
        elif method == 'textDocument/didOpen':
            self._handle_did_open(params)
        elif method == 'textDocument/didChange':
            self._handle_did_change(params)
        elif method == 'textDocument/didClose':
            self._handle_did_close(params)
        elif method == 'textDocument/hover':
            self._handle_hover(msg_id, params)
        elif method == 'textDocument/definition':
            self._handle_definition(msg_id, params)
        elif method == 'textDocument/documentSymbol':
            self._handle_document_symbol(msg_id, params)
        elif method == 'textDocument/completion':
            self._handle_completion(msg_id, params)
        elif method == 'textDocument/signatureHelp':
            self._handle_signature_help(msg_id, params)
        elif method == 'textDocument/references':
            self._handle_references(msg_id, params)
        elif method == 'workspace/symbol':
            self._handle_workspace_symbol(msg_id, params)
        elif method == 'shutdown':
            self._shutdown_requested = True
            self._write({'id': msg_id, 'result': None})
        elif method == 'exit':
            sys.exit(0)

    def _log(self, msg: str):
        self._write({
            'method': 'window/logMessage',
            'params': {'type': 4, 'message': msg}
        })

    # ===== Document Management =====

    def _get_text(self, uri: str) -> str:
        return self.documents.get(uri, '')

    def _uri_to_path(self, uri: str) -> str:
        parsed = urlparse(uri)
        return unquote(parsed.path)

    def _path_to_uri(self, path: str) -> str:
        from urllib.parse import quote
        return 'file://' + quote(path, safe='/:@')

    def _analyze(self, uri: str, text: str):
        try:
            tokens = tokenize(text)
            program = parse(tokens, uri)
            inferer = TypeInferer()
            types = inferer.infer(program)

            # Build name -> location map (definitions)
            name_locations = {}
            for defn in program.definitions:
                loc = defn.loc
                if isinstance(defn, FnDef):
                    name_locations[defn.name] = {
                        'line': loc.line - 1 if loc else 0,
                        'col': loc.col - 1 if loc else 0,
                        'end_col': loc.col - 1 + len(defn.name) if loc else 0,
                    }
                elif isinstance(defn, TypeDef):
                    name_locations[defn.name] = {
                        'line': loc.line - 1 if loc else 0,
                        'col': loc.col - 1 if loc else 0,
                        'end_col': loc.col - 1 + len(defn.name) if loc else 0,
                    }
                    for ctor in defn.constructors:
                        c_loc = ctor.loc
                        name_locations[ctor.name] = {
                            'line': c_loc.line - 1 if c_loc else 0,
                            'col': c_loc.col - 1 if c_loc else 0,
                            'end_col': c_loc.col - 1 + len(ctor.name) if c_loc else 0,
                        }
                elif isinstance(defn, LetBinding):
                    name_locations[defn.name] = {
                        'line': loc.line - 1 if loc else 0,
                        'col': loc.col - 1 if loc else 0,
                        'end_col': loc.col - 1 + len(defn.name) if loc else 0,
                    }

            # Build diagnostics: type errors + semantic errors
            diagnostics = self._build_diagnostics(inferer.errors, 'ko-typecheck')

            # Add semantic exhaustiveness warnings
            source_lines = text.split('\n')
            semantic_bundle = check_exhaustiveness(program, source_lines, uri)
            for sem_diag in semantic_bundle.diagnostics:
                loc = sem_diag.location
                if loc:
                    line = loc.line - 1
                    col = loc.col - 1
                    end_col = loc.span_end if loc.span_end else col + 1
                else:
                    line = col = 0
                    end_col = 1
                diagnostics.append({
                    'range': {
                        'start': {'line': line, 'character': col},
                        'end': {'line': line, 'character': end_col}
                    },
                    'severity': 2,  # Warning
                    'message': str(sem_diag.message),
                    'source': 'ko-semantic',
                })

            self.type_cache[uri] = {
                'types': {name: str(scheme) for name, scheme in types.items()},
                'errors': diagnostics,
                'locations': name_locations,
                'program': program,
            }

            # Rebuild global symbol table for cross-file features
            self._rebuild_global_state()

            self._publish_diagnostics(uri, diagnostics)

        except Exception as e:
            diagnostics = self._extract_error_diagnostics(e)
            self.type_cache[uri] = {
                'types': {},
                'errors': diagnostics,
                'locations': {},
                'program': None,
            }
            self._rebuild_global_state()
            self._publish_diagnostics(uri, diagnostics)

    def _rebuild_global_state(self):
        """Rebuild the global symbol table and workspace symbols from all cached programs."""
        symbol_table: Dict[str, List[Dict]] = {}
        workspace_symbols: List[Dict] = []

        for uri, cache in self.type_cache.items():
            locations = cache.get('locations', {})
            program = cache.get('program')
            if not program:
                continue

            # Add definitions to symbol table
            for name, loc in locations.items():
                entry = {
                    'uri': uri,
                    'range': {
                        'start': {'line': loc['line'], 'character': loc['col']},
                        'end': {'line': loc['line'], 'character': loc['end_col']},
                    },
                    'is_definition': True,
                }
                symbol_table.setdefault(name, []).append(entry)

            # Collect usages (identifier references) from AST
            usages = self._collect_usages(program, uri)
            for name, ranges in usages.items():
                for rng in ranges:
                    entry = {
                        'uri': uri,
                        'range': rng,
                        'is_definition': False,
                    }
                    symbol_table.setdefault(name, []).append(entry)

            # Build flat workspace symbol list
            symbol_kind_map = {
                FnDef: 12,      # Function
                TypeDef: 5,     # Enum/ADT
                LetBinding: 13, # Variable
            }
            for defn in program.definitions:
                kind = symbol_kind_map.get(type(defn))
                if kind is None:
                    continue
                loc = defn.loc
                workspace_symbols.append({
                    'name': defn.name,
                    'kind': kind,
                    'location': {
                        'uri': uri,
                        'range': {
                            'start': {'line': loc.line - 1 if loc else 0, 'character': loc.col - 1 if loc else 0},
                            'end': {'line': loc.line - 1 if loc else 0, 'character': (loc.col - 1 if loc else 0) + len(defn.name)},
                        }
                    },
                })
                # Add type constructors as symbols too
                if isinstance(defn, TypeDef):
                    for ctor in defn.constructors:
                        c_loc = ctor.loc
                        workspace_symbols.append({
                            'name': ctor.name,
                            'kind': 11,  # Constructor
                            'location': {
                                'uri': uri,
                                'range': {
                                    'start': {'line': c_loc.line - 1 if c_loc else 0, 'character': c_loc.col - 1 if c_loc else 0},
                                    'end': {'line': c_loc.line - 1 if c_loc else 0, 'character': (c_loc.col - 1 if c_loc else 0) + len(ctor.name)},
                                }
                            },
                        })

        self.symbol_table = symbol_table
        self.workspace_symbols = workspace_symbols

    def _collect_usages(self, program: Program, uri: str) -> Dict[str, List[Dict]]:
        """Walk AST and collect all identifier references (usages)."""
        usages: Dict[str, List[Dict]] = {}

        def add_usage(name: str, line: int, col: int, end_col: int):
            usages.setdefault(name, []).append({
                'start': {'line': line, 'character': col},
                'end': {'line': line, 'character': end_col},
            })

        def walk_expr(expr: Optional[Expr]):
            if expr is None:
                return
            if isinstance(expr, Identifier):
                loc = expr.loc
                if loc:
                    add_usage(
                        expr.name,
                        loc.line - 1,
                        loc.col - 1,
                        loc.col - 1 + len(expr.name),
                    )
            elif isinstance(expr, Block):
                for e in expr.exprs:
                    walk_expr(e)
            elif isinstance(expr, LetExpr):
                walk_expr(expr.value)
                walk_expr(expr.body)
            elif isinstance(expr, IfExpr):
                walk_expr(expr.cond)
                walk_expr(expr.then_branch)
                walk_expr(expr.else_branch)
            elif isinstance(expr, Lambda):
                walk_expr(expr.body)
            elif isinstance(expr, FnCall):
                walk_expr(expr.func)
                for arg in expr.args:
                    walk_expr(arg)
            elif isinstance(expr, BinaryOp):
                walk_expr(expr.left)
                walk_expr(expr.right)
            elif isinstance(expr, UnaryOp):
                walk_expr(expr.expr)
            elif isinstance(expr, MatchExpr):
                walk_expr(expr.value)
                for arm in expr.arms:
                    walk_pattern(arm.pattern)
                    walk_expr(arm.body)

        def walk_pattern(pattern):
            if isinstance(pattern, PatConstructor):
                loc = pattern.loc
                if loc:
                    add_usage(
                        pattern.name,
                        loc.line - 1,
                        loc.col - 1,
                        loc.col - 1 + len(pattern.name),
                    )
                for sub in pattern.args:
                    walk_pattern(sub)
            elif isinstance(pattern, PatIdent):
                pass  # bindings, not usages

        for defn in program.definitions:
            if isinstance(defn, FnDef):
                walk_expr(defn.body)
            elif isinstance(defn, LetBinding):
                walk_expr(defn.value)

        return usages

    def _build_diagnostics(self, errors, source: str) -> List[dict]:
        diagnostics = []
        for err in errors:
            line, col, end_line, end_col = self._extract_location(err)
            diagnostics.append({
                'range': {
                    'start': {'line': line, 'character': col},
                    'end': {'line': end_line, 'character': end_col}
                },
                'severity': 1,
                'message': str(err),
                'source': source,
            })
        return diagnostics

    def _extract_location(self, err) -> Tuple[int, int, int, int]:
        location = getattr(err, 'location', None)
        if location is not None:
            line = location.line - 1 if getattr(location, 'line', None) else 0
            col = location.col - 1 if getattr(location, 'col', None) else 0
            end_col = getattr(location, 'end_col', col + 1) or col + 1
            return (line, col, line, end_col)
        tok = getattr(err, 'token', None)
        if tok is not None:
            line = tok.line - 1 if getattr(tok, 'line', None) else 0
            col = tok.col - 1 if getattr(tok, 'col', None) else 0
            end_col = tok.col if getattr(tok, 'col', None) else col + 1
            return (line, col, line, end_col)
        return (0, 0, 0, 1)

    def _extract_error_diagnostics(self, exc) -> List[dict]:
        line, col, end_line, end_col = self._extract_location(exc)
        return [{
            'range': {
                'start': {'line': line, 'character': col},
                'end': {'line': end_line, 'character': end_col}
            },
            'severity': 1,
            'message': str(exc),
            'source': 'ko',
        }]

    def _publish_diagnostics(self, uri: str, diagnostics: List[dict]):
        self._write({
            'method': 'textDocument/publishDiagnostics',
            'params': {'uri': uri, 'diagnostics': diagnostics}
        })

    # ===== LSP Handlers =====

    def _handle_initialize(self, msg_id: int, params: dict):
        result = {
            'capabilities': {
                'textDocumentSync': {
                    'openClose': True,
                    'change': 1,
                    'save': {'includeText': True},
                },
                'hoverProvider': True,
                'definitionProvider': True,
                'documentSymbolProvider': True,
                'completionProvider': {
                    'triggerCharacters': [],
                    'resolveProvider': False,
                },
                'signatureHelpProvider': {
                    'triggerCharacters': ['('],
                },
                'referencesProvider': True,
                'workspaceSymbolProvider': True,
            },
            'serverInfo': {
                'name': 'ko-language-server',
                'version': '0.2.1',
            },
        }
        self._write({'id': msg_id, 'result': result})

    def _handle_did_open(self, params: dict):
        uri = params['textDocument']['uri']
        text = params['textDocument']['text']
        self.documents[uri] = text
        self._analyze(uri, text)

    def _handle_did_change(self, params: dict):
        uri = params['textDocument']['uri']
        text = params['contentChanges'][0]['text']
        self.documents[uri] = text
        self._analyze(uri, text)

    def _handle_did_close(self, params: dict):
        uri = params['textDocument']['uri']
        self.documents.pop(uri, None)
        self.type_cache.pop(uri, None)
        self._rebuild_global_state()
        self._publish_diagnostics(uri, [])

    # ----- Hover -----

    BUILTIN_DOCS = {
        'print': '`print value` — Print value without newline\n\n`value : any` — The value to print\n\n```ko\nprint 42\nprint "hello"\n```',
        'println': '`println value` — Print value with newline\n\n`value : any` — The value to print\n\n```ko\nprintln 42\nprintln "hello"\n```',
        'inspect': '`inspect value` — Debug print with type info\n\n`value : any` — The value to inspect\n\n```ko\ninspect 42       // Int: 42\ninspect "hello"   // String: "hello"\n```',
        'panic': '`panic message` — Exit with error message\n\n`message : String` — Error message to display\n\n```ko\npanic "something went wrong"\n```',
        'len': '`len s` — String length\n\n`s : String` — The string\n\n```ko\nlen "hello"  // 5\n```',
        'concat': '`concat a b` — Concatenate two strings\n\n`a : String` — First string\n`b : String` — Second string\n\n```ko\nconcat "hello" " world"  // "hello world"\n```',
        'char_at': '`char_at s i` — Character at index\n\n`s : String` — The string\n`i : Int` — Zero-based index\n\n```ko\nchar_at "hello" 1  // \'e\'\n```',
        'substring': '`substring s start end` — Extract substring [start, end)\n\n`s : String` — The string\n`start : Int` — Start index (inclusive)\n`end : Int` — End index (exclusive)\n\n```ko\nsubstring "hello" 1 4  // "ell"\n```',
        'contains': '`contains s sub` — Check if substring exists\n\n`s : String` — The string\n`sub : String` — Substring to find\n\n```ko\ncontains "hello world" "world"  // true\n```',
        'to_upper': '`to_upper s` — Convert to uppercase\n\n`s : String` — The string\n\n```ko\nto_upper "hello"  // "HELLO"\n```',
        'to_lower': '`to_lower s` — Convert to lowercase\n\n`s : String` — The string\n\n```ko\to_lower "HELLO"  // "hello"\n```',
        'trim': '`trim s` — Remove leading/trailing whitespace\n\n`s : String` — The string\n\n```ko\ntrim "  hello  "  // "hello"\n```',
        'starts_with': '`starts_with s prefix` — Check prefix\n\n`s : String` — The string\n`prefix : String` — Prefix to check\n\n```ko\nstarts_with "hello" "hel"  // true\n```',
        'ends_with': '`ends_with s suffix` — Check suffix\n\n`s : String` — The string\n`suffix : String` — Suffix to check\n\n```ko\nends_with "hello" "llo"  // true\n```',
        'repeat': '`repeat s n` — Repeat string n times\n\n`s : String` — The string\n`n : Int` — Number of repetitions\n\n```ko\nrepeat "ha" 3  // "hahaha"\n```',
        'split': '`split s delim` — Split string by delimiter\n\n`s : String` — The string\n`delim : String` — Delimiter\n\n```ko\nsplit "a,b,c" ","  // ["a", "b", "c"]\n```',
        'join': '`join xs sep` — Join list elements with separator\n\n`xs : List` — List of strings\n`sep : String` — Separator\n\n```ko\njoin ["a" "b" "c"] "-"  // "a-b-c"\n```',
        'replace': '`replace s old new` — Replace all occurrences\n\n`s : String` — The string\n`old : String` — Substring to replace\n`new : String` — Replacement string\n\n```ko\nreplace "hello world" "world" "ko"  // "hello ko"\n```',
        'ord': '`ord c` — Convert character to code point\n\n`c : Char` — The character\n\n```ko\nord \'A\'  // 65\n```',
        'chr': '`chr n` — Convert code point to character\n\n`n : Int` — Unicode code point\n\n```ko\nchr 65  // \'A\'\n```',
        'parse_int': '`parse_int s` — Parse string as integer\n\n`s : String` — String to parse\n\n```ko\nparse_int "42"  // 42\n```',
        'parse_float': '`parse_float s` — Parse string as float\n\n`s : String` — String to parse\n\n```ko\nparse_float "3.14"  // 3.14\n```',
        'abs': '`abs n` — Absolute value\n\n`n : Int` — The number\n\n```ko\nabs (-5)  // 5\nabs 5     // 5\n```',
        'min': '`min a b` — Minimum of two ints\n\n`a : Int` — First number\n`b : Int` — Second number\n\n```ko\nmin 3 7  // 3\n```',
        'max': '`max a b` — Maximum of two ints\n\n`a : Int` — First number\n`b : Int` — Second number\n\n```ko\nmax 3 7  // 7\n```',
        'pow': '`pow base exp` — Raise base to power\n\n`base : Int` — Base number\n`exp : Int` — Exponent\n\n```ko\npow 2 10  // 1024\n```',
        'sqrt': '`sqrt x` — Square root\n\n`x : Float` — The number\n\n```ko\nsqrt 16.0  // 4.0\n```',
        'floor': '`floor x` — Round down to integer\n\n`x : Float` — The number\n\n```ko\nfloor 3.7  // 3\n```',
        'ceil': '`ceil x` — Round up to integer\n\n`x : Float` — The number\n\n```ko\nceil 3.2  // 4\n```',
        'mod': '`mod a b` — Modulo (remainder)\n\n`a : Int` — Dividend\n`b : Int` — Divisor\n\n```ko\nmod 10 3  // 1\n```',
        'to_string': '`to_string v` — Convert value to string\n\n`v : any` — The value\n\n```ko\to_string 42     // "42"\nto_string true   // "true"\n```',
        'to_int': '`to_int s` — Convert string to int\n\n`s : String` — String to convert\n\n```ko\to_int "42"  // 42\n```',
        'to_float': '`to_float v` — Convert value to float\n\n`v : any` — The value\n\n```ko\to_float "3.14"  // 3.14\to_float 42      // 42.0\n```',
        'type_of': '`type_of v` — Get type name as string\n\n`v : any` — The value\n\n```ko\ntype_of 42      // "Int"\ntype_of "hello"  // "String"\n```',
        'is_int': '`is_int v` — Check if value is Int\n\n`v : any` — The value\n\n```ko\nis_int 42       // true\nis_int "hello"  // false\n```',
        'is_float': '`is_float v` — Check if value is Float\n\n`v : any` — The value\n\n```ko\nis_float 3.14   // true\nis_float 42     // false\n```',
        'is_string': '`is_string v` — Check if value is String\n\n`v : any` — The value\n\n```ko\nis_string "hello"  // true\nis_string 42       // false\n```',
        'is_bool': '`is_bool v` — Check if value is Bool\n\n`v : any` — The value\n\n```ko\nis_bool true   // true\nis_bool 42     // false\n```',
        'is_null': '`is_null v` — Check if value is null constructor\n\n`v : any` — The value\n\n```ko\nis_null Null  // true\n```',
        'read_file': '`read_file path` — Read entire file as string\n\n`path : String` — File path\n\n```ko\nlet content = read_file "data.txt"\n```',
        'write_file': '`write_file path content` — Write string to file\n\n`path : String` — File path\n`content : String` — Content to write\n\n```ko\nwrite_file "output.txt" "hello world"\n```',
        'append_file': '`append_file path content` — Append string to file\n\n`path : String` — File path\n`content : String` — Content to append\n\n```ko\nappend_file "log.txt" "new line\\n"\n```',
        'read_line': '`read_line prompt` — Read line from stdin\n\n`prompt : String` — Prompt to display\n\n```ko\nlet name = read_line "Enter name: "\n```',
        'run': '`run cmd` — Run shell command, return output\n\n`cmd : String` — Shell command\n\n```ko\nlet output = run "ls -la"\n```',
        'get_env': '`get_env name` — Get environment variable\n\n`name : String` — Variable name\n\n```ko\nlet home = get_env "HOME"\n```',
        'file_exists': '`file_exists path` — Check if file exists\n\n`path : String` — File path\n\n```ko\nif file_exists "config.ko" then ...\n```',
        'sleep': '`sleep ms` — Sleep for N milliseconds\n\n`ms : Int` — Milliseconds\n\n```ko\nsleep 1000  // sleep 1 second\n```',
        'eprint': '`eprint value` — Print to stderr without newline\n\n`value : any` — The value to print\n\n```ko\neprint "error: something failed"\n```',
        'eprintln': '`eprintln value` — Print to stderr with newline\n\n`value : any` — The value to print\n\n```ko\neprintln "error: something failed"\n```',
        'mkdir': '`mkdir path` — Create directory\n\n`path : String` — Directory path\n\n```ko\nmkdir "output"\n```',
        'rm': '`rm path` — Remove file\n\n`path : String` — File path\n\n```ko\nrm "temp.txt"\n```',
        'cp': '`cp src dst` — Copy file\n\n`src : String` — Source path\n`dst : String` — Destination path\n\n```ko\ncp "data.txt" "data.backup.txt"\n```',
        'mv': '`mv src dst` — Move/rename file\n\n`src : String` — Source path\n`dst : String` — Destination path\n\n```ko\nmv "old.txt" "new.txt"\n```',
        'readdir': '`readdir path` — List directory contents\n\n`path : String` — Directory path\n\n```ko\nlet files = readdir "."\n```',
        'file_size': '`file_size path` — Get file size in bytes\n\n`path : String` — File path\n\n```ko\nlet size = file_size "data.txt"\n```',
        'file_modified': '`file_modified path` — Get last modification time\n\n`path : String` — File path\n\n```ko\nlet mtime = file_modified "data.txt"\n```',
        'path_join': '`path_join a b` — Join path components\n\n`a : String` — First component\n`b : String` — Second component\n\n```ko\npath_join "src" "main.ko"  // "src/main.ko"\npath_join "dir/" "file"    // "dir/file"\n```',
        'path_dirname': '`path_dirname path` — Get directory part of path\n\n`path : String` — File path\n\n```ko\npath_dirname "src/main.ko"  // "src"\npath_dirname "file.txt"     // "."\n```',
        'path_basename': '`path_basename path` — Get filename part of path\n\n`path : String` — File path\n\n```ko\npath_basename "src/main.ko"  // "main.ko"\npath_basename "/a/b/c.txt"   // "c.txt"\n```',
        'json_parse': '`json_parse s` — Parse JSON string to Kō values\n\n`s : String` — JSON string\n\nObjects → list of pairs, Arrays → lists, null → Nil\n\n```ko\nlet data = json_parse "{\\"name\\": \\"Kō\\", \\"version\\": 2}"\n```',
        'json_stringify': '`json_stringify v` — Convert Kō value to JSON string\n\n`v : any` — The value\n\n```ko\njson_stringify 42           // "42"\njson_stringify "hello"      // "\\"hello\\""\njson_stringify [1, 2, 3]    // "[1,2,3]"\n```',
        'args_count': '`args_count` — Number of command line arguments\n\n```ko\nif args_count > 1 then ...\n```',
        'args_get': '`args_get i` — Get CLI argument by index\n\n`i : Int` — Argument index\n\n```ko\nlet file = args_get 1  // first argument\n```',
        'now': '`now` — Milliseconds since program start\n\n```ko\nlet start = now\n// ... do work ...\nlet elapsed = now - start\n```',
        'random': '`random seed min max` — Pure random\n\n`seed : Int` — Random seed\n`min : Int` — Minimum value\n`max : Int` — Maximum value\n\n```ko\nlet r = random 42 1 100  // random between 1-100\n```',
        'seed': '`seed` — Get next seed for chaining\n\n```ko\nlet s = seed\nlet r = random s 1 100\n```',
        'exit': '`exit code` — Exit program with code\n\n`code : Int` — Exit code (0 = success)\n\n```ko\nexit 0   // success\nexit 1   // error\n```',
        'assert': '`assert cond` — Assert condition is true\n\n`cond : Bool` — Condition to check\n\n```ko\nassert (1 + 1 == 2)\n```',
        'assert_eq': '`assert_eq a b` — Assert two values are equal\n\n`a : any` — First value\n`b : any` — Second value\n\n```ko\nassert_eq (add 2 3) 5\n```',
        'test': '`test name result` — Run a named test group\n\n`name : String` — Test name\n`result : any` — Result to check (truthy = pass)\n\n```ko\ntest "addition" (2 + 3 == 5)\n```',
        'run_tests': '`run_tests` — Print test summary and exit\n\n```ko\nrun_tests\n```',
        'head': '`head xs` — First element of list\n\n`xs : List` — The list\n\n```ko\nhead [1, 2, 3]  // 1\n```',
        'tail': '`tail xs` — All but first element\n\n`xs : List` — The list\n\n```ko\ntail [1, 2, 3]  // [2, 3]\n```',
        'append': '`append xs x` — Append element to end\n\n`xs : List` — The list\n`x : any` — Element to append\n\n```ko\nappend [1, 2] 3  // [1, 2, 3]\n```',
        'reverse': '`reverse xs` — Reverse a list\n\n`xs : List` — The list\n\n```ko\nreverse [1, 2, 3]  // [3, 2, 1]\n```',
        'sum': '`sum xs` — Sum all integers\n\n`xs : List[Int]` — List of integers\n\n```ko\nsum [1, 2, 3]  // 6\n```',
        'product': '`product xs` — Product of all integers\n\n`xs : List[Int]` — List of integers\n\n```ko\nproduct [2, 3, 4]  // 24\n```',
        'ref': '`ref : forall a. a -> a` — Create mutable reference',
        '!': '`! : forall a. a -> a` — Dereference a reference',
        ':=': '`:= : forall a. a -> a -> Unit` — Mutate a reference',
    }

    def _handle_hover(self, msg_id: int, params: dict):
        uri = params['textDocument']['uri']
        position = params['position']
        line = position['line']
        col = position['character']

        text = self._get_text(uri)
        lines = text.split('\n')
        if line >= len(lines):
            self._write({'id': msg_id, 'result': None})
            return

        word = self._get_word_at(lines[line], col)
        if not word:
            self._write({'id': msg_id, 'result': None})
            return

        cache = self.type_cache.get(uri, {})
        types = cache.get('types', {})
        locations = cache.get('locations', {})
        program = cache.get('program')

        # --- Builtin documentation (rich, pre-authored) ---
        if word in self.BUILTIN_DOCS:
            contents = {'kind': 'markdown', 'value': self.BUILTIN_DOCS[word]}
            self._write({'id': msg_id, 'result': {'contents': contents}})
            return

        # --- Look up the definition across all loaded files ---
        defn_info = self._find_definition(word, program, uri)

        if defn_info:
            md = self._build_hover_markdown(word, defn_info, types, locations, lines, line)
            contents = {'kind': 'markdown', 'value': md}
            self._write({'id': msg_id, 'result': {'contents': contents}})
            return

        # --- Fallback: just show the type if available ---
        if word in types:
            type_str = types[word]
            loc_info = ''
            if word in locations:
                loc = locations[word]
                loc_info = f'  \n*defined at line {loc["line"] + 1}*'
            contents = {
                'kind': 'markdown',
                'value': f'**{word}** : `{type_str}`{loc_info}'
            }
            self._write({'id': msg_id, 'result': {'contents': contents}})
            return

        self._write({'id': msg_id, 'result': None})

    def _find_definition(self, name: str, program, uri: str):
        """Find a definition node by name across the current file and global state."""
        if program:
            for defn in program.definitions:
                if isinstance(defn, FnDef) and defn.name == name:
                    return {'kind': 'fn', 'defn': defn}
                if isinstance(defn, TypeDef) and defn.name == name:
                    return {'kind': 'type', 'defn': defn}
                if isinstance(defn, LetBinding) and defn.name == name:
                    return {'kind': 'let', 'defn': defn}
                # Check type constructors
                if isinstance(defn, TypeDef):
                    for ctor in defn.constructors:
                        if ctor.name == name:
                            return {'kind': 'ctor', 'defn': ctor, 'parent': defn}

        # Check global symbol table (cross-file)
        if name in self.symbol_table:
            for entry in self.symbol_table[name]:
                if entry.get('is_definition') and entry.get('uri', '') != uri:
                    return {'kind': 'external', 'defn': None, 'external': True}
        return None

    def _build_hover_markdown(self, name, defn_info, types, locations, lines, line_num):
        """Build rich markdown hover content."""
        kind = defn_info['kind']
        defn = defn_info.get('defn')
        type_str = types.get(name, '')

        # --- Type definition hover ---
        if kind == 'type' and defn:
            ctors = ' | '.join(
                f"**{c.name}** {'*' * c.fields if c.fields else ''}"
                for c in defn.constructors
            )
            type_params = ' '.join(defn.type_params) if defn.type_params else ''
            header = f'(type) **{name}**{f"\\<\\{type_params}\\>" if type_params else ""}'
            loc_info = self._location_info(name, locations, line_num)
            return f'{header}\n\n```ko\ntype {name} {type_params} = {ctors}\n```{loc_info}'

        # --- Constructor hover ---
        if kind == 'ctor' and defn:
            parent = defn_info.get('parent')
            parent_name = parent.name if parent else '?'
            field_types = ' '.join(defn.field_types) if defn.field_types else ''
            header = f'(constructor) **{name}**'
            sig = f'```ko\n{name} {field_types or ("* " * defn.fields)}\n```' if (defn.fields or defn.field_types) else f'```ko\n{name}\n```'
            loc_info = self._location_info(name, locations, line_num)
            return f'{header} of **{parent_name}**\n\n{sig}{loc_info}'

        # --- Function hover ---
        if kind == 'fn' and defn:
            header = f'(function) **{name}**'
            # Build full signature: name param1 param2 ... -> ReturnType
            params_str = ' '.join(defn.params) if defn.params else ''
            # Extract return type from type_str: "A -> B -> C" -> "C"
            ret_type = self._extract_return_type(type_str)
            full_sig = f'{name} {params_str}'.strip()
            if ret_type and ret_type != 'Unit':
                full_sig += f' -> {ret_type}'
            elif params_str:
                full_sig += ' -> Unit'
            sig_block = f'```ko\n{full_sig}\n```'

            # Docstring from comment above the definition
            doc = self._extract_docstring(lines, line_num)
            doc_block = f'\n\n{doc}' if doc else ''

            loc_info = self._location_info(name, locations, line_num)
            return f'{header}\n\n{sig_block}{doc_block}{loc_info}'

        # --- Let binding hover ---
        if kind == 'let' and defn:
            header = f'(value) **{name}**'
            type_block = f' : `{type_str}`' if type_str else ''
            loc_info = self._location_info(name, locations, line_num)
            return f'{header}{type_block}{loc_info}'

        # --- Fallback: just type ---
        if type_str:
            loc_info = self._location_info(name, locations, line_num)
            return f'**{name}** : `{type_str}`{loc_info}'

        return f'**{name}**'

    def _extract_return_type(self, type_str: str) -> str:
        """Extract the return type from a function type string like 'Int -> String -> Bool'."""
        if '->' not in type_str:
            return type_str
        # Split on ' -> ' (with spaces) to avoid confusion with nested arrows
        parts = [p.strip() for p in type_str.split('->')]
        return parts[-1] if parts else type_str

    def _location_info(self, name: str, locations: dict, current_line: int) -> str:
        """Build a 'defined at line N' suffix."""
        loc = locations.get(name)
        if loc:
            line_num = loc['line'] + 1
            return f'\n\n*defined at line {line_num}*'
        return ''

    def _extract_docstring(self, lines, def_line: int) -> str:
        """Extract a comment docstring immediately above a definition."""
        # Look backwards from the definition line for a contiguous block of # comments
        i = def_line - 1
        while i >= 0 and lines[i].strip() == '':
            i -= 1
        comments = []
        while i >= 0 and lines[i].strip().startswith('#'):
            comments.append(lines[i].strip().lstrip('#').strip())
            i -= 1
        if not comments:
            return ''
        comments.reverse()
        return '\n'.join(comments)

    # ----- Go-to-definition -----

    def _handle_definition(self, msg_id: int, params: dict):
        uri = params['textDocument']['uri']
        position = params['position']
        line = position['line']
        col = position['character']

        text = self._get_text(uri)
        lines = text.split('\n')
        if line >= len(lines):
            self._write({'id': msg_id, 'result': None})
            return

        word = self._get_word_at(lines[line], col)
        if not word:
            self._write({'id': msg_id, 'result': None})
            return

        cache = self.type_cache.get(uri, {})
        locations = cache.get('locations', {})

        if word in locations:
            loc = locations[word]
            self._write({
                'id': msg_id,
                'result': {
                    'uri': uri,
                    'range': {
                        'start': {'line': loc['line'], 'character': loc['col']},
                        'end': {'line': loc['line'], 'character': loc['end_col']}
                    }
                }
            })
            return

        program = cache.get('program')
        if program:
            for imp in program.imports:
                if not isinstance(imp, Import):
                    continue
                if imp.alias and imp.alias == word:
                    if imp.loc:
                        self._write({
                            'id': msg_id,
                            'result': {
                                'uri': uri,
                                'range': {
                                    'start': {'line': imp.loc.line - 1, 'character': imp.loc.col - 1},
                                    'end': {'line': imp.loc.line - 1, 'character': imp.loc.col - 1 + len(imp.path)}
                                }
                            }
                        })
                        return
                imported_uri = self._resolve_import_uri(imp.path, uri)
                if imported_uri and imported_uri in self.type_cache:
                    imported_cache = self.type_cache[imported_uri]
                    imported_locations = imported_cache.get('locations', {})
                    if word in imported_locations:
                        loc = imported_locations[word]
                        self._write({
                            'id': msg_id,
                            'result': {
                                'uri': imported_uri,
                                'range': {
                                    'start': {'line': loc['line'], 'character': loc['col']},
                                    'end': {'line': loc['line'], 'character': loc['end_col']}
                                }
                            }
                        })
                        return

        self._write({'id': msg_id, 'result': None})

    def _resolve_import_uri(self, import_path: str, from_uri: str) -> Optional[str]:
        from_dir = str(Path(self._uri_to_path(from_uri)).parent)
        candidates = [
            os.path.join(from_dir, import_path),
            os.path.join(from_dir, import_path + '.ko'),
            os.path.join(from_dir, import_path, 'mod.ko'),
        ]
        for candidate in candidates:
            if os.path.isfile(candidate):
                return self._path_to_uri(candidate)
        return None

    # ----- Document symbols -----

    def _handle_document_symbol(self, msg_id: int, params: dict):
        uri = params['textDocument']['uri']
        cache = self.type_cache.get(uri, {})
        program = cache.get('program')
        if not program:
            self._write({'id': msg_id, 'result': []})
            return

        symbols = []
        for defn in program.definitions:
            if isinstance(defn, FnDef):
                loc = defn.loc
                symbols.append({
                    'name': defn.name,
                    'kind': 12,
                    'location': {
                        'uri': uri,
                        'range': {
                            'start': {'line': loc.line - 1 if loc else 0, 'character': loc.col - 1 if loc else 0},
                            'end': {'line': loc.line - 1 if loc else 0, 'character': (loc.col - 1 if loc else 0) + len(defn.name)}
                        }
                    },
                })
            elif isinstance(defn, TypeDef):
                loc = defn.loc
                symbols.append({
                    'name': defn.name,
                    'kind': 5,
                    'location': {
                        'uri': uri,
                        'range': {
                            'start': {'line': loc.line - 1 if loc else 0, 'character': loc.col - 1 if loc else 0},
                            'end': {'line': loc.line - 1 if loc else 0, 'character': (loc.col - 1 if loc else 0) + len(defn.name)}
                        }
                    },
                    'children': [
                        {
                            'name': ctor.name,
                            'kind': 11,
                            'location': {
                                'uri': uri,
                                'range': {
                                    'start': {'line': ctor.loc.line - 1 if ctor.loc else 0, 'character': ctor.loc.col - 1 if ctor.loc else 0},
                                    'end': {'line': ctor.loc.line - 1 if ctor.loc else 0, 'character': (ctor.loc.col - 1 if ctor.loc else 0) + len(ctor.name)}
                                }
                            },
                        }
                        for ctor in defn.constructors
                    ],
                })
            elif isinstance(defn, LetBinding):
                loc = defn.loc
                symbols.append({
                    'name': defn.name,
                    'kind': 13,
                    'location': {
                        'uri': uri,
                        'range': {
                            'start': {'line': loc.line - 1 if loc else 0, 'character': loc.col - 1 if loc else 0},
                            'end': {'line': loc.line - 1 if loc else 0, 'character': (loc.col - 1 if loc else 0) + len(defn.name)}
                        }
                    },
                })

        self._write({'id': msg_id, 'result': symbols})

    # ----- Completions -----

    def _handle_completion(self, msg_id: int, params: dict):
        uri = params['textDocument']['uri']
        items = []

        keywords = [
            ('fn', 'Define a function'),
            ('let', 'Bind a value (immutable)'),
            ('if', 'Conditional expression'),
            ('else', 'Else branch'),
            ('then', 'Then branch'),
            ('match', 'Pattern matching'),
            ('type', 'Define algebraic data type'),
            ('import', 'Import a module'),
            ('as', 'Alias for import'),
            ('ref', 'Create a mutable reference'),
            ('comptime', 'Evaluate at compile time'),
            ('in', 'Body of let expression'),
        ]
        for name, doc in keywords:
            items.append({'label': name, 'kind': 14, 'detail': doc})

        builtins = [
            'print', 'println', 'inspect', 'panic',
            'len', 'concat', 'char_at', 'substring', 'contains',
            'to_upper', 'to_lower', 'trim', 'starts_with', 'ends_with',
            'repeat', 'split', 'join', 'replace', 'ord', 'chr',
            'parse_int', 'parse_float',
            'abs', 'min', 'max', 'pow', 'sqrt', 'floor', 'ceil', 'mod',
            'to_string', 'to_int', 'to_float', 'type_of',
            'is_int', 'is_float', 'is_string', 'is_bool', 'is_null',
            'read_file', 'write_file', 'append_file', 'read_line',
            'run', 'get_env', 'file_exists', 'sleep',
            'args_count', 'args_get', 'now', 'exit',
            'eprint', 'eprintln',
            'mkdir', 'rm', 'cp', 'mv', 'readdir',
            'file_size', 'file_modified',
            'path_join', 'path_dirname', 'path_basename',
            'json_parse', 'json_stringify',
            'random', 'seed',
            'assert', 'assert_eq', 'test', 'run_tests',
            'head', 'tail', 'append', 'reverse', 'sum', 'product',
        ]
        for name in builtins:
            items.append({'label': name, 'kind': 3})

        cache = self.type_cache.get(uri, {})
        types = cache.get('types', {})
        for name, type_str in types.items():
            items.append({
                'label': name,
                'kind': 12 if '(' in type_str or '->' in type_str else 13,
                'detail': type_str,
            })

        self._write({'id': msg_id, 'result': {'items': items}})

    # ----- Signature Help -----

    def _handle_signature_help(self, msg_id: int, params: dict):
        uri = params['textDocument']['uri']
        position = params['position']
        line = position['line']
        col = position['character']

        text = self._get_text(uri)
        lines = text.split('\n')
        if line >= len(lines):
            self._write({'id': msg_id, 'result': None})
            return

        func_name = self._find_function_at_call(lines, line, col)
        if not func_name:
            self._write({'id': msg_id, 'result': None})
            return

        cache = self.type_cache.get(uri, {})
        types = cache.get('types', {})

        if func_name in self.BUILTIN_DOCS:
            doc = self.BUILTIN_DOCS[func_name]
            sig = self._extract_signature_from_doc(doc)
            signatures = [{
                'label': sig or f'{func_name}(...)',
                'documentation': {'kind': 'markdown', 'value': doc},
                'parameters': self._guess_parameters(doc),
            }]
            active_param = self._count_open_parens(lines, line, col)
            self._write({
                'id': msg_id,
                'result': {
                    'signatures': signatures,
                    'activeSignature': 0,
                    'activeParameter': active_param,
                }
            })
            return

        if func_name in types:
            type_str = types[func_name]
            program = cache.get('program')
            params_list = []
            if program:
                for defn in program.definitions:
                    if isinstance(defn, FnDef) and defn.name == func_name:
                        params_list = defn.params
                        break
            sig_label = f'{func_name}(' + ', '.join(params_list) + ')'
            parameters = [{'label': p} for p in params_list]
            signatures = [{
                'label': sig_label,
                'documentation': {'kind': 'markdown', 'value': f'`{type_str}`'},
                'parameters': parameters,
            }]
            active_param = self._count_open_parens(lines, line, col)
            self._write({
                'id': msg_id,
                'result': {
                    'signatures': signatures,
                    'activeSignature': 0,
                    'activeParameter': active_param,
                }
            })
            return

        self._write({'id': msg_id, 'result': None})

    def _find_function_at_call(self, lines: List[str], line: int, col: int) -> Optional[str]:
        """Find the function name at the current call site (before '(')."""
        current_line = lines[line][:col] if col <= len(lines[line]) else lines[line]
        match = re.search(r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\([^)]*$', current_line)
        if match:
            return match.group(1)
        if line > 0:
            prev_line = lines[line - 1].rstrip()
            match = re.search(r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\s*$', prev_line)
            if match:
                return match.group(1)
        return None

    def _extract_signature_from_doc(self, doc: str) -> Optional[str]:
        """Extract first code-fenced signature from doc."""
        match = re.search(r'`([^`]+)`', doc)
        return match.group(1) if match else None

    def _guess_parameters(self, doc: str) -> List[Dict]:
        """Guess parameter names from builtin doc format."""
        params = []
        for line in doc.split('\n'):
            m = re.match(r'`(\w+)\s*:\s*(\w+)`', line.strip())
            if m:
                params.append({'label': m.group(1), 'documentation': f'`{m.group(2)}`'})
        return params

    def _count_open_parens(self, lines: List[str], line: int, col: int) -> int:
        """Count which parameter position the cursor is at."""
        text_before = ''
        for i in range(line + 1):
            if i == line:
                text_before += lines[i][:col]
            else:
                text_before += lines[i]
        depth = 0
        current_param = 0
        for ch in text_before:
            if ch == '(':
                depth += 1
                if depth == 1:
                    current_param = 0
            elif ch == ',' and depth == 1:
                current_param += 1
            elif ch == ')':
                depth = max(0, depth - 1)
        return current_param if depth > 0 else 0

    # ----- Find References -----

    def _handle_references(self, msg_id: int, params: dict):
        uri = params['textDocument']['uri']
        position = params['position']
        line = position['line']
        col = position['character']

        text = self._get_text(uri)
        lines = text.split('\n')
        if line >= len(lines):
            self._write({'id': msg_id, 'result': None})
            return

        word = self._get_word_at(lines[line], col)
        if not word or word not in self.symbol_table:
            self._write({'id': msg_id, 'result': None})
            return

        refs = []
        for entry in self.symbol_table[word]:
            refs.append({
                'uri': entry['uri'],
                'range': entry['range'],
            })

        self._write({'id': msg_id, 'result': refs})

    # ----- Workspace Symbols -----

    def _handle_workspace_symbol(self, msg_id: int, params: dict):
        query = params.get('query', '').lower()
        if not query:
            self._write({'id': msg_id, 'result': self.workspace_symbols[:200]})
            return

        results = [
            sym for sym in self.workspace_symbols
            if query in sym['name'].lower()
        ]
        self._write({'id': msg_id, 'result': results[:200]})

    # ===== Helpers =====

    def _get_word_at(self, line: str, col: int) -> Optional[str]:
        if col > len(line):
            return None
        start = col
        while start > 0 and (line[start-1].isalnum() or line[start-1] in '_-'):
            start -= 1
        end = col
        while end < len(line) and (line[end].isalnum() or line[end] in '_-'):
            end += 1
        word = line[start:end]
        return word if word else None


if __name__ == '__main__':
    server = LSPServer()
    server.run()
