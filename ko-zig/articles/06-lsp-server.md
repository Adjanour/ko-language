# Article 6: Building an LSP Server Without Dependencies

## Target Audience
Tooling developers, VS Code extension authors, developers building language tools.

## Tone
Practical, detailed, with working code. This is a "build it yourself" article.

## Word Count
3,000-4,000 words

## Structure

### Hook (200 words)
- Kō has an LSP server: hover, completion, diagnostics
- It's written in Zig, with no external dependencies
- It uses raw syscalls for I/O, not the standard library
- Promise: by the end, you'll understand how to build your own LSP server

### The Problem: Why Build an LSP Server? (400 words)
- IDE support makes languages usable
- Without an LSP server, developers are flying blind
- The Language Server Protocol (LSP) is the standard
- VS Code, Vim, Emacs, and others all support LSP
- Building one from scratch teaches you about your language

### What Is LSP? (500 words)

#### The Protocol
- JSON-RPC over stdio
- Client sends requests, server responds
- Client sends notifications, server processes them
- Key methods: `initialize`, `textDocument/didOpen`, `textDocument/hover`, `textDocument/completion`, `textDocument/definition`

#### The Capabilities
- **Hover**: Show type information when hovering over identifiers
- **Completion**: Suggest completions as you type
- **Diagnostics**: Show errors and warnings in real-time
- **Go to Definition**: Jump to where a function is defined

### Kō's LSP Architecture (600 words)

#### The Binary
- Separate binary `ko-lsp` — no LLVM dependency
- Imports only parser + typechecker
- Much smaller than the main compiler

#### The Document Store
```zig
const DocumentStore = struct {
    documents: std.StringHashMap(Document),
    allocator: Allocator,
};

const Document = struct {
    uri: []const u8,
    text: []const u8,
    ast: ?Program,
    types: ?TypeMap,
    errors: []Error,
};
```

#### The Processing Pipeline
1. Receive `textDocument/didOpen` notification
2. Parse the source code
3. Typecheck the AST
4. Store the results in the document store
5. Send diagnostics back to the client

### The I/O Challenge (600 words)

#### Why Raw Syscalls?
- The Zig standard library's `Io` doesn't work well with subprocess pipes
- `Io.File.Reader` uses `sendFile` for streaming, which returns 0 on pipes
- Solution: use raw Linux syscalls directly

#### The Read Pattern
```zig
fn rawRead(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (rc < 0) {
        const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
        return switch (e) {
            .INTR => rawRead(fd, buf),  // retry on interrupt
            else => error.ReadFailed,
        };
    }
    if (rc == 0) return error.EndOfStream;
    return @intCast(rc);
}
```

#### The Write Pattern
```zig
fn writeAll(fd: i32, data: []const u8) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        const rc = if (comptime @import("builtin").os.tag == .linux)
            linux.write(fd, data[pos..].ptr, data.len - pos)
        else
            std.c.write(fd, data[pos..].ptr, data.len - pos);
        if (rc < 0) {
            const e: linux.E = @enumFromInt(@as(u16, @intCast(-% @as(isize, @intCast(rc)))));
            switch (e) {
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        pos += @intCast(rc);
    }
}
```

#### The Header Parsing
```zig
fn readLine(fd: i32, line_buf: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < line_buf.len) {
        const n = rawRead(fd, line_buf[line_len .. line_len + 1]) catch |err| {
            if (err == error.EndOfStream) return error.ConnectionClosed;
            return err;
        };
        if (n == 0) return error.ConnectionClosed;
        if (line_buf[line_len] == '\n') break;
        line_len += n;
    }
    // Strip trailing \r if present
    const end = if (line_len > 0 and line_buf[line_len - 1] == '\r') line_len - 1 else line_len;
    return line_buf[0..end];
}
```

### Implementing Hover (500 words)

#### The Request
```json
{
  "method": "textDocument/hover",
  "params": {
    "textDocument": { "uri": "file:///path/to/file.ko" },
    "position": { "line": 5, "character": 10 }
  }
}
```

#### The Response
```json
{
  "contents": {
    "kind": "markdown",
    "value": "**add** : `Int -> Int -> Int`\n\nAdds two integers"
  }
}
```

#### The Implementation
1. Find the document in the store
2. Parse the source to find the identifier at the position
3. Look up the type in the type environment
4. Format the type as markdown
5. Return the response

#### Type Pretty-Printing
- `typeToString(alloc, type)` converts `Type` to human-readable string
- Follows `variable.instance` chain to resolve type variables
- Handles: `Int`, `Float`, `Bool`, `String`, `Char`, `()`, arrows, tuples, constructors, records, refs
- Arrow types auto-parenthesize: `(Int -> Int) -> Int`

### Implementing Completion (500 words)

#### The Request
```json
{
  "method": "textDocument/completion",
  "params": {
    "textDocument": { "uri": "file:///path/to/file.ko" },
    "position": { "line": 5, "character": 10 }
  }
}
```

#### The Response
```json
{
  "items": [
    {
      "label": "add",
      "kind": 3,
      "detail": "Int -> Int -> Int",
      "documentation": "Adds two integers"
    },
    {
      "label": "head",
      "kind": 3,
      "detail": "List a -> a",
      "documentation": "Returns the first element of a list"
    }
  ]
}
```

#### The Implementation
1. Find the document in the store
2. Get the partial identifier at the position
3. Search the type environment for matching names
4. Format each match as a completion item
5. Return the response

### Implementing Diagnostics (400 words)

#### The Notification
```json
{
  "method": "textDocument/didOpen",
  "params": {
    "textDocument": {
      "uri": "file:///path/to/file.ko",
      "text": "fn add x y = x + y"
    }
  }
}
```

#### The Response
```json
{
  "method": "textDocument/publishDiagnostics",
  "params": {
    "uri": "file:///path/to/file.ko",
    "diagnostics": [
      {
        "range": {
          "start": { "line": 0, "character": 13 },
          "end": { "line": 0, "character": 14 }
        },
        "severity": 1,
        "message": "Expected Int, got String"
      }
    ]
  }
}
```

#### The Implementation
1. Parse the source code
2. Typecheck the AST
3. Collect all errors
4. Format each error as a diagnostic
5. Send the notification

### The Main Loop (400 words)

```zig
fn main() !void {
    var store = DocumentStore.init(allocator);
    defer store.deinit();

    while (true) {
        // Read Content-Length header
        const content_length = readContentLength() catch |err| {
            if (err == error.ConnectionClosed) break;
            return err;
        };

        // Read the JSON-RPC message
        const message = readMessage(content_length);

        // Parse the JSON
        const parsed = try std.json.parseFromSlice(Message, allocator, message, .{});
        defer parsed.deinit();

        // Handle the message
        switch (parsed.method) {
            "initialize" => try handleInitialize(parsed.params),
            "textDocument/didOpen" => try handleDidOpen(&store, parsed.params),
            "textDocument/hover" => try handleHover(&store, parsed.params),
            "textDocument/completion" => try handleCompletion(&store, parsed.params),
            "textDocument/definition" => try handleDefinition(&store, parsed.params),
            "shutdown" => break,
            else => {},
        }
    }
}
```

### Gotchas (400 words)

#### Gotcha 1: Don't Increment line_len on \n
```zig
if (line_buf[line_len] == '\n') break;  // DON'T increment line_len
```
The original code did `line_len += 1; break;` which included the `\n` in the returned line.

#### Gotcha 2: Strip Trailing \r
- LSP uses `\r\n` line endings
- The `\r` must be stripped from the line
- Otherwise, header parsing fails

#### Gotcha 3: JSON-RPC Requires Specific Error Format
- Errors must be JSON-RPC error objects
- Not just plain strings
- Must include code, message, and optional data

#### Gotcha 4: Completion Needs Partial Identifier
- The position is at the end of the partial identifier
- Must extract the partial identifier from the source
- Search for names that start with the partial identifier

### The VS Code Extension (400 words)

#### The Architecture
- Extension in `vscode-ko/`
- TextMate grammar for syntax highlighting
- LSP client via `vscode-languageclient`
- LSP server launched as `ko-lsp` subprocess

#### The TextMate Grammar
```json
{
  "patterns": [
    {
      "name": "keyword.control.ko",
      "match": "\\b(fn|let|if|then|else|match|type|import|package|pub|module|ref|comptime|not|and|or)\\b"
    },
    {
      "name": "support.type.ko",
      "match": "\\b(Int|Float|Bool|String|Char|Unit)\\b"
    }
  ]
}
```

#### The LSP Client
```json
{
  "configurationProperties": {
    "ko.lsp.path": {
      "type": "string",
      "default": "ko-lsp",
      "description": "Path to the Kō LSP server"
    }
  }
}
```

### Performance (300 words)
- LSP must be fast: hover, completion, diagnostics must be instant
- Kō's approach: incremental parsing (future), fast typechecking
- The parser is ~100ms for typical files
- The typechecker is ~50ms for typical files
- Total: ~150ms per keystroke (acceptable for LSP)

### Lessons Learned (300 words)
- Raw syscalls are tedious but reliable
- JSON parsing in Zig is straightforward
- The LSP protocol is well-documented but complex
- Error handling is critical — the server must never crash
- Testing with VS Code is invaluable

### Conclusion (200 words)
- Building an LSP server teaches you about your language
- The LSP protocol is standardized and well-supported
- Raw syscalls work, but are tedious
- The result: a usable IDE experience for Kō
- The next step: incremental parsing, better completion

---

## Key Code Snippets to Include

1. The raw read/write patterns
2. The header parsing
3. The main loop
4. The hover implementation
5. The completion implementation
6. The diagnostic formatting

## Images/Diagrams
1. The LSP architecture (client → server → document store)
2. The processing pipeline (parse → typecheck → store → respond)
3. The I/O flow (stdin → parse → process → stdout)
4. The hover response format
5. The completion response format

## Publishing Platforms
- Personal blog
- VS Code blog (if polished enough)
- Reddit (r/vscode, r/programming)
- Hacker News
- Dev.to
