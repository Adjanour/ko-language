#!/usr/bin/env python3
"""
Kō Language Server Protocol (LSP) server.
Provides type inference, hover info, diagnostics, go-to-definition,
completion, and document symbols.
"""

import os
import sys
import json
import re
import traceback
from typing import Dict, List, Optional, Any, Tuple
from pathlib import Path
from urllib.parse import urlparse, unquote

# Import Kō compiler modules
sys.path.insert(0, str(Path(__file__).parent))
from lexer import tokenize, Token
from parser import parse, Program, FnDef, TypeDef, LetBinding, LetExpr, Identifier, MatchExpr, Import
from typecheck import TypeInferer, TypeScheme, TypeError as KoTypeError


# ===== LSP Protocol Layer =====

class LSPServer:
    """Minimal LSP server over stdio."""

    def __init__(self):
        self.documents: Dict[str, str] = {}  # uri -> content
        self.type_cache: Dict[str, Dict] = {}  # uri -> {types, errors, locations, program}
        self.initialized = False
        self._shutdown_requested = False

    def run(self):
        """Main loop: read messages from stdin, dispatch, write responses."""
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
        """Read LSP header (Content-Length: N\\r\\n\\r\\n)."""
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
        """Read exactly `length` bytes from stdin."""
        body = b''
        while len(body) < length:
            chunk = sys.stdin.buffer.read(length - len(body))
            if not chunk:
                raise EOFError
            body += chunk
        return body.decode('utf-8')

    def _write(self, msg: dict):
        """Write an LSP message to stdout."""
        body = json.dumps(msg)
        content = f"Content-Length: {len(body.encode('utf-8'))}\r\n\r\n{body}"
        sys.stdout.buffer.write(content.encode('utf-8'))
        sys.stdout.buffer.flush()

    def _dispatch(self, msg: dict):
        """Route message to handler."""
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
        elif method == 'shutdown':
            self._shutdown_requested = True
            self._write({'id': msg_id, 'result': None})
        elif method == 'exit':
            sys.exit(0)

    def _log(self, msg: str):
        """Send log message to client."""
        self._write({
            'method': 'window/logMessage',
            'params': {
                'type': 4,  # Info
                'message': msg
            }
        })

    # ===== Document Management =====

    def _get_text(self, uri: str) -> str:
        return self.documents.get(uri, '')

    def _uri_to_path(self, uri: str) -> str:
        """Convert file:// URI to local path."""
        parsed = urlparse(uri)
        return unquote(parsed.path)

    def _path_to_uri(self, path: str) -> str:
        """Convert local path to file:// URI."""
        from urllib.parse import quote
        return 'file://' + quote(path, safe='/:@')

    def _analyze(self, uri: str, text: str):
        """Parse and type-check a document, cache results."""
        try:
            tokens = tokenize(text)
            program = parse(tokens, uri)
            inferer = TypeInferer()
            types = inferer.infer(program)

            # Build name -> location map
            name_locations = {}
            for defn in program.definitions:
                if isinstance(defn, FnDef):
                    name_locations[defn.name] = {
                        'line': defn.loc.line - 1 if defn.loc else 0,
                        'col': defn.loc.col - 1 if defn.loc else 0,
                        'end_col': defn.loc.col - 1 + len(defn.name) if defn.loc else 0,
                    }
                elif isinstance(defn, TypeDef):
                    name_locations[defn.name] = {
                        'line': defn.loc.line - 1 if defn.loc else 0,
                        'col': defn.loc.col - 1 if defn.loc else 0,
                        'end_col': defn.loc.col - 1 + len(defn.name) if defn.loc else 0,
                    }
                    for ctor in defn.constructors:
                        name_locations[ctor.name] = {
                            'line': ctor.loc.line - 1 if ctor.loc else 0,
                            'col': ctor.loc.col - 1 if ctor.loc else 0,
                            'end_col': ctor.loc.col - 1 + len(ctor.name) if ctor.loc else 0,
                        }
                elif isinstance(defn, LetBinding):
                    name_locations[defn.name] = {
                        'line': defn.loc.line - 1 if defn.loc else 0,
                        'col': defn.loc.col - 1 if defn.loc else 0,
                        'end_col': defn.loc.col - 1 + len(defn.name) if defn.loc else 0,
                    }

            # Build diagnostics from type errors
            diagnostics = self._build_diagnostics(inferer.errors, 'ko-typecheck')

            self.type_cache[uri] = {
                'types': {name: str(scheme) for name, scheme in types.items()},
                'errors': diagnostics,
                'locations': name_locations,
                'program': program,
            }

            # Publish diagnostics
            self._publish_diagnostics(uri, diagnostics)

        except Exception as e:
            # Parse error or other failure — extract location from exception
            diagnostics = self._extract_error_diagnostics(e)
            self.type_cache[uri] = {
                'types': {},
                'errors': diagnostics,
                'locations': {},
                'program': None,
            }
            self._publish_diagnostics(uri, diagnostics)

    def _build_diagnostics(self, errors, source: str) -> List[dict]:
        """Convert a list of type errors to LSP diagnostics."""
        diagnostics = []
        for err in errors:
            line, col, end_line, end_col = self._extract_location(err)
            diagnostics.append({
                'range': {
                    'start': {'line': line, 'character': col},
                    'end': {'line': end_line, 'character': end_col}
                },
                'severity': 1,  # Error
                'message': str(err),
                'source': source,
            })
        return diagnostics

    def _extract_location(self, err) -> Tuple[int, int, int, int]:
        """Extract (line, col, end_line, end_col) 0-indexed from a type/parse error."""
        # typecheck.TypeError has .location (SourceLocation)
        location = getattr(err, 'location', None)
        if location is not None:
            line = location.line - 1 if getattr(location, 'line', None) else 0
            col = location.col - 1 if getattr(location, 'col', None) else 0
            end_col = getattr(location, 'end_col', col + 1) or col + 1
            return (line, col, line, end_col)

        # parser.ParseError has .token (Token)
        tok = getattr(err, 'token', None)
        if tok is not None:
            line = tok.line - 1 if getattr(tok, 'line', None) else 0
            col = tok.col - 1 if getattr(tok, 'col', None) else 0
            end_col = tok.col if getattr(tok, 'col', None) else col + 1
            return (line, col, line, end_col)

        return (0, 0, 0, 1)

    def _extract_error_diagnostics(self, exc) -> List[dict]:
        """Build diagnostics from a thrown exception (parse errors, etc.)."""
        # Check if the exception carries location info
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
        """Push diagnostics to the client."""
        self._write({
            'method': 'textDocument/publishDiagnostics',
            'params': {
                'uri': uri,
                'diagnostics': diagnostics,
            }
        })

    # ===== Handlers =====

    def _handle_initialize(self, msg_id: int, params: dict):
        result = {
            'capabilities': {
                'textDocumentSync': {
                    'openClose': True,
                    'change': 1,  # Full sync
                    'save': {'includeText': True},
                },
                'hoverProvider': True,
                'definitionProvider': True,
                'documentSymbolProvider': True,
                'completionProvider': {
                    'triggerCharacters': [],
                    'resolveProvider': False,
                },
            },
            'serverInfo': {
                'name': 'ko-language-server',
                'version': '0.1.0',
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
        # Full sync: text is the entire document
        text = params['contentChanges'][0]['text']
        self.documents[uri] = text
        self._analyze(uri, text)

    def _handle_did_close(self, params: dict):
        uri = params['textDocument']['uri']
        self.documents.pop(uri, None)
        self.type_cache.pop(uri, None)
        self._publish_diagnostics(uri, [])

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

        # Find word at cursor
        word = self._get_word_at(lines[line], col)
        if not word:
            self._write({'id': msg_id, 'result': None})
            return

        cache = self.type_cache.get(uri, {})
        types = cache.get('types', {})

        # Check builtins first (has rich docs)
        builtin_docs = {
            # I/O
            'print': '`print : forall a. a -> Unit` — Print value without newline',
            'println': '`println : forall a. a -> Unit` — Print value with newline',
            'inspect': '`inspect : forall a. a -> Unit` — Debug print with type info',
            'panic': '`panic : String -> Unit` — Exit with error message',
            # String operations
            'len': '`len : String -> Int` — String length',
            'concat': '`concat : String -> String -> String` — Concatenate two strings',
            'char_at': '`char_at : String -> Int -> Char` — Character at index',
            'substring': '`substring : String -> Int -> Int -> String` — Extract substring [start, end)',
            'contains': '`contains : String -> String -> Bool` — Check if substring exists',
            'to_upper': '`to_upper : String -> String` — Convert to uppercase',
            'to_lower': '`to_lower : String -> String` — Convert to lowercase',
            'trim': '`trim : String -> String` — Remove leading/trailing whitespace',
            'starts_with': '`starts_with : String -> String -> Bool` — Check prefix',
            'ends_with': '`ends_with : String -> String -> Bool` — Check suffix',
            'repeat': '`repeat : String -> Int -> String` — Repeat string n times',
            'split': '`split : String -> String -> List` — Split string by delimiter',
            'join': '`join : List -> String -> String` — Join list elements with separator',
            'replace': '`replace : String -> String -> String -> String` — Replace all occurrences',
            'ord': '`ord : Char -> Int` — Convert character to code point',
            'chr': '`chr : Int -> Char` — Convert code point to character',
            'parse_int': '`parse_int : String -> Int` — Parse string as integer',
            'parse_float': '`parse_float : String -> Float` — Parse string as float',
            # Math
            'abs': '`abs : Int -> Int` — Absolute value',
            'min': '`min : Int -> Int -> Int` — Minimum of two ints',
            'max': '`max : Int -> Int -> Int` — Maximum of two ints',
            'pow': '`pow : Int -> Int -> Int` — Raise base to power',
            'sqrt': '`sqrt : Float -> Float` — Square root',
            'floor': '`floor : Float -> Int` — Round down to integer',
            'ceil': '`ceil : Float -> Int` — Round up to integer',
            'mod': '`mod : Int -> Int -> Int` — Modulo (remainder)',
            # Type conversion & introspection
            'to_string': '`to_string : forall a. a -> String` — Convert value to string',
            'to_int': '`to_int : String -> Int` — Convert string to int',
            'to_float': '`to_float : forall a. a -> Float` — Convert value to float',
            'type_of': '`type_of : forall a. a -> String` — Get type name as string',
            'is_int': '`is_int : forall a. a -> Bool` — Check if value is Int',
            'is_float': '`is_float : forall a. a -> Bool` — Check if value is Float',
            'is_string': '`is_string : forall a. a -> Bool` — Check if value is String',
            'is_bool': '`is_bool : forall a. a -> Bool` — Check if value is Bool',
            'is_null': '`is_null : forall a. a -> Bool` — Check if value is null constructor',
            # File & system I/O
            'read_file': '`read_file : String -> String` — Read entire file as string',
            'write_file': '`write_file : String -> String -> Unit` — Write string to file',
            'append_file': '`append_file : String -> String -> Unit` — Append string to file',
            'read_line': '`read_line : String -> String` — Read line from stdin (with prompt)',
            'run': '`run : String -> String` — Run shell command, return output',
            'get_env': '`get_env : String -> String` — Get environment variable value',
            'file_exists': '`file_exists : String -> Bool` — Check if file exists',
            'sleep': '`sleep : Int -> Unit` — Sleep for N milliseconds',
            # CLI arguments
            'args_count': '`args_count : Int` — Number of command line arguments',
            'args_get': '`args_get : Int -> String` — Get CLI argument by index',
            # Time
            'now': '`now : Int` — Milliseconds since program start',
            # Random
            'random': '`random : Int -> Int -> Int -> Int` — Pure random (seed, min, max)',
            'seed': '`seed : Int` — Get next seed for chaining',
            # System
            'exit': '`exit : Int -> Unit` — Exit program with code',
            # Testing
            'assert': '`assert : Bool -> Unit` — Assert condition is true',
            'assert_eq': '`assert_eq : forall a. a -> a -> Unit` — Assert two values are equal',
            'test': '`test : forall a. String -> a -> Unit` — Run a named test group',
            'run_tests': '`run_tests : Unit` — Print test summary and exit',
            # List operations
            'head': '`head : forall a. List[a] -> a` — First element of list',
            'tail': '`tail : forall a. List[a] -> List[a]` — All but first element',
            'append': '`append : forall a. List[a] -> a -> List[a]` — Append element to end',
            'reverse': '`reverse : forall a. List[a] -> List[a]` — Reverse a list',
            'sum': '`sum : List[Int] -> Int` — Sum all integers in list',
            'product': '`product : List[Int] -> Int` — Product of all integers in list',
            # Reference cells
            'ref': '`ref : forall a. a -> a` — Create mutable reference',
            '!': '`! : forall a. a -> a` — Dereference a reference',
            ':=': '`:= : forall a. a -> a -> Unit` — Mutate a reference',
        }

        if word in builtin_docs:
            contents = {
                'kind': 'markdown',
                'value': builtin_docs[word]
            }
            self._write({'id': msg_id, 'result': {'contents': contents}})
            return

        # Check type cache (user-defined names)
        if word in types:
            type_str = types[word]
            # Enrich with source location info
            locations = cache.get('locations', {})
            loc_info = ''
            if word in locations:
                loc = locations[word]
                loc_info = f'  \n*defined at line {loc["line"] + 1}, col {loc["col"] + 1}*'

            # Enrich FnDef with param info
            program = cache.get('program')
            fn_info = ''
            if program:
                for defn in program.definitions:
                    if isinstance(defn, FnDef) and defn.name == word:
                        params_str = ', '.join(defn.params)
                        fn_info = f'  \n`{word} {params_str}`'
                        break

            contents = {
                'kind': 'markdown',
                'value': f'**{word}** : `{type_str}`{fn_info}{loc_info}'
            }
            self._write({'id': msg_id, 'result': {'contents': contents}})
            return

        self._write({'id': msg_id, 'result': None})

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

        # Check local definitions first
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

        # Check imported modules
        program = cache.get('program')
        if program:
            for imp in program.imports:
                if not isinstance(imp, Import):
                    continue
                # Check alias match
                if imp.alias and imp.alias == word:
                    # Alias: go to the import statement itself
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

                # Check if the word is defined in the imported module
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
        """Resolve an import path to a file URI."""
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
                kind = 12  # Function
                loc = defn.loc
                symbols.append({
                    'name': defn.name,
                    'kind': kind,
                    'location': {
                        'uri': uri,
                        'range': {
                            'start': {'line': loc.line - 1 if loc else 0, 'character': loc.col - 1 if loc else 0},
                            'end': {'line': loc.line - 1 if loc else 0, 'character': (loc.col - 1 if loc else 0) + len(defn.name)}
                        }
                    },
                })
            elif isinstance(defn, TypeDef):
                kind = 5  # Enum (ADT)
                loc = defn.loc
                symbols.append({
                    'name': defn.name,
                    'kind': kind,
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
                            'kind': 11,  # Constructor
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
                kind = 13  # Variable
                loc = defn.loc
                symbols.append({
                    'name': defn.name,
                    'kind': kind,
                    'location': {
                        'uri': uri,
                        'range': {
                            'start': {'line': loc.line - 1 if loc else 0, 'character': loc.col - 1 if loc else 0},
                            'end': {'line': loc.line - 1 if loc else 0, 'character': (loc.col - 1 if loc else 0) + len(defn.name)}
                        }
                    },
                })

        self._write({'id': msg_id, 'result': symbols})

    def _handle_completion(self, msg_id: int, params: dict):
        """Provide completion items for keywords, builtins, and user-defined names."""
        uri = params['textDocument']['uri']
        position = params['position']
        line = position['line']
        col = position['character']

        text = self._get_text(uri)
        lines = text.split('\n')
        prefix = ''
        if line < len(lines):
            prefix = lines[line][:col]

        items = []

        # Keywords
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
            items.append({
                'label': name,
                'kind': 14,  # Keyword
                'detail': doc,
            })

        # Builtins
        builtins = [
            # I/O
            'print', 'println', 'inspect', 'panic',
            # String ops
            'len', 'concat', 'char_at', 'substring', 'contains',
            'to_upper', 'to_lower', 'trim', 'starts_with', 'ends_with',
            'repeat', 'split', 'join', 'replace', 'ord', 'chr',
            'parse_int', 'parse_float',
            # Math
            'abs', 'min', 'max', 'pow', 'sqrt', 'floor', 'ceil', 'mod',
            # Type conversion
            'to_string', 'to_int', 'to_float', 'type_of',
            'is_int', 'is_float', 'is_string', 'is_bool', 'is_null',
            # File & system
            'read_file', 'write_file', 'append_file', 'read_line',
            'run', 'get_env', 'file_exists', 'sleep',
            'args_count', 'args_get', 'now', 'exit',
            # Random
            'random', 'seed',
            # Testing
            'assert', 'assert_eq', 'test', 'run_tests',
            # List ops
            'head', 'tail', 'append', 'reverse', 'sum', 'product',
            # Refs
            'ref',
        ]
        for name in builtins:
            items.append({
                'label': name,
                'kind': 3,  # Function
            })

        # User-defined names from type cache
        cache = self.type_cache.get(uri, {})
        types = cache.get('types', {})
        for name, type_str in types.items():
            items.append({
                'label': name,
                'kind': 12 if '(' in type_str or '->' in type_str else 13,  # Function or Variable
                'detail': type_str,
            })

        self._write({'id': msg_id, 'result': {'items': items}})

    # ===== Helpers =====

    def _get_word_at(self, line: str, col: int) -> Optional[str]:
        """Extract word at cursor position."""
        if col > len(line):
            return None
        # Find word boundaries (include ! and := which are operators)
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
